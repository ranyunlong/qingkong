FROM python:3.13-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    QINGKONG_CONTENT_DB=/data/content.sqlite3

WORKDIR /app
RUN groupadd --gid 10001 qingkong \
    && useradd --uid 10001 --gid qingkong --no-create-home --shell /usr/sbin/nologin qingkong \
    && mkdir /data \
    && chown qingkong:qingkong /data \
    && chmod 700 /data
COPY requirements.txt /app/ContentService/requirements.txt
RUN pip install --no-cache-dir -r /app/ContentService/requirements.txt
COPY __init__.py server.py configure.py richtext.py images.py admin_style.css admin_editor.js media_inspection.py /app/ContentService/
USER 10001:10001
EXPOSE 8787
CMD ["python", "-m", "ContentService.server", "--host", "0.0.0.0", "--port", "8787"]
