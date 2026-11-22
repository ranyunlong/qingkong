"""Bounded, isolated article image decoding and content-addressed storage."""
import hashlib
import multiprocessing
import os
import sys
import tempfile
import threading
import time
import warnings
from pathlib import Path

from PIL import Image, ImageOps, UnidentifiedImageError


MAX_BYTES = 10 * 1024 * 1024
MAX_PIXELS = 20_000_000
MAX_DIMENSION = 10000
OUTPUT_DIMENSION = 2560
MAX_OUTPUT_BYTES = 8 * 1024 * 1024
TOTAL_TIMEOUT = 25.0
PARSER_MEMORY_BYTES = 384 * 1024 * 1024
MIME_FORMATS = {'image/jpeg': 'JPEG', 'image/png': 'PNG', 'image/webp': 'WEBP'}
_UPLOADS = threading.BoundedSemaphore(1)


class ImageUploadError(ValueError):
    """An upload failure safe to show to an editor."""


def _remaining(deadline):
    seconds = deadline - time.monotonic()
    if seconds <= 0:
        raise ImageUploadError('图片处理超时，请稍后重试')
    return seconds


def _normalize(source, destination, expected_format):
    Image.MAX_IMAGE_PIXELS = MAX_PIXELS
    with warnings.catch_warnings():
        warnings.simplefilter('error', Image.DecompressionBombWarning)
        with Image.open(source, formats=list(MIME_FORMATS.values())) as original:
            if original.format != expected_format:
                raise ImageUploadError('图片真实格式与文件类型不一致')
            width, height = original.size
            if (width < 1 or height < 1 or max(width, height) > MAX_DIMENSION
                    or width * height > MAX_PIXELS):
                raise ImageUploadError('图片最多 2000 万像素，单边不超过 10000 像素')
            if getattr(original, 'n_frames', 1) != 1:
                raise ImageUploadError('请上传静态 JPEG、PNG 或 WebP 图片')
            original.load()
            oriented = ImageOps.exif_transpose(original)
            oriented.thumbnail((OUTPUT_DIMENSION, OUTPUT_DIMENSION), Image.Resampling.LANCZOS)
            # Copy only pixel data; no EXIF, ICC, text chunks or source metadata.
            mode = 'RGB' if expected_format == 'JPEG' else ('RGBA' if 'A' in oriented.getbands() or 'transparency' in oriented.info else 'RGB')
            converted = oriented.convert(mode)
            clean = Image.frombytes(mode, converted.size, converted.tobytes())
            output_format = 'JPEG' if expected_format == 'JPEG' else 'PNG'
            options = {'quality': 88} if output_format == 'JPEG' else {}
            while True:
                clean.save(destination, format=output_format, **options)
                if Path(destination).stat().st_size <= MAX_OUTPUT_BYTES:
                    break
                clean = clean.resize((max(1, int(clean.width * .75)), max(1, int(clean.height * .75))),
                                     Image.Resampling.LANCZOS)
            return {'width': clean.width, 'height': clean.height,
                    'extension': 'jpg' if output_format == 'JPEG' else 'png'}


def _worker(source, destination, expected_format, sender):
    try:
        if sys.platform.startswith('linux'):
            import resource
            resource.setrlimit(resource.RLIMIT_AS, (PARSER_MEMORY_BYTES, PARSER_MEMORY_BYTES))
            resource.setrlimit(resource.RLIMIT_CPU, (15, 15))
        sender.send((True, _normalize(source, destination, expected_format)))
    except ImageUploadError as error:
        sender.send((False, str(error)))
    except (Image.DecompressionBombError, Image.DecompressionBombWarning, MemoryError):
        sender.send((False, '图片超过尺寸或内存限制，请缩小后重试'))
    except (UnidentifiedImageError, OSError, ValueError, SyntaxError):
        sender.send((False, '无法读取图片，请上传有效的 JPEG、PNG 或 WebP 文件'))
    except Exception:
        sender.send((False, '图片处理失败，请换一张图片重试'))
    finally:
        sender.close()


def _parse(source, destination, expected_format, deadline):
    context = multiprocessing.get_context('spawn')
    receiver, sender = context.Pipe(duplex=False)
    process = context.Process(target=_worker, args=(source, destination, expected_format, sender), daemon=True)
    started = False
    try:
        process.start()
        started = True
        sender.close()
        if not receiver.poll(_remaining(deadline)):
            raise ImageUploadError('图片处理超时，请缩小后重试')
        try:
            success, result = receiver.recv()
        except EOFError:
            raise ImageUploadError('图片处理超过限制或文件已损坏') from None
        if not success:
            raise ImageUploadError(result)
        _remaining(deadline)
        return result
    finally:
        receiver.close()
        sender.close()
        if started:
            if process.is_alive():
                process.terminate()
            process.join(timeout=.5)
            if process.is_alive():
                process.kill()
                process.join(timeout=.5)
            process.close()


def store_image(stream, length, mime, directory):
    """Read one bounded body and atomically store normalized pixels, without DB writes."""
    if mime not in MIME_FORMATS:
        raise ImageUploadError('仅支持 JPEG、PNG 或 WebP 图片')
    if not 0 < length <= MAX_BYTES:
        raise ImageUploadError('单张图片不能为空或超过 10 MiB')
    if not _UPLOADS.acquire(blocking=False):
        raise ImageUploadError('正在处理其他图片，请稍后重试')
    deadline = time.monotonic() + TOTAL_TIMEOUT
    try:
        directory = Path(directory)
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        # Work under the same filesystem so the final content-addressed rename is atomic.
        with tempfile.TemporaryDirectory(prefix='.image-', dir=directory) as temporary:
            source, destination = Path(temporary) / 'source', Path(temporary) / 'result'
            with source.open('wb') as upload:
                remaining = length
                while remaining:
                    _remaining(deadline)
                    chunk = stream.read1(min(65536, remaining))
                    _remaining(deadline)
                    if not chunk:
                        raise ImageUploadError('图片上传不完整，请重试')
                    upload.write(chunk)
                    remaining -= len(chunk)
            result = _parse(str(source), str(destination), MIME_FORMATS[mime], deadline)
            digest = hashlib.sha256()
            with destination.open('rb') as normalized:
                while chunk := normalized.read(65536):
                    digest.update(chunk)
            filename = digest.hexdigest() + '.' + result.pop('extension')
            result['byteSize'] = destination.stat().st_size
            os.replace(destination, directory / filename)
            return filename, result
    except (TimeoutError, OSError):
        raise ImageUploadError('图片上传或保存失败，请稍后重试') from None
    finally:
        _UPLOADS.release()
