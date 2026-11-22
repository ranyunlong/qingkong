"""Interactively create a private Docker Compose environment without default credentials."""
import argparse
import getpass
import os
import re
import secrets
from pathlib import Path

from .server import password_hash


def write_environment(path, username, password):
    if not re.fullmatch(r"[A-Za-z0-9._-]{1,64}", username):
        raise ValueError("管理员名称限 1～64 位字母、数字、点、下划线或短横线")
    encoded = password_hash(password)
    # Single quotes preserve PBKDF2's dollar separators during Compose interpolation.
    content = ("# 由部署配置工具生成；请勿提交、公开或用 shell source 加载。\n"
               f"QINGKONG_ADMIN_USERNAME='{username}'\n"
               f"QINGKONG_ADMIN_PASSWORD_HASH='{encoded}'\n"
               f"QINGKONG_SESSION_SECRET='{secrets.token_urlsafe(48)}'\n"
               "QINGKONG_CONTENT_PORT=8787\n")
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as output:
        output.write(content)


def main():
    parser = argparse.ArgumentParser(description="生成小晴空 Docker 部署凭据，不覆盖已有文件")
    parser.add_argument("--output", type=Path, default=Path(".env"))
    args = parser.parse_args()
    if args.output.exists():
        parser.error("目标文件已存在，已保留原配置；如需更换凭据，请先备份后手工编辑")
    username = input("管理员名称 [editor]：").strip() or "editor"
    password = getpass.getpass("管理员密码（至少 12 字符）：")
    confirmation = getpass.getpass("再次输入管理员密码：")
    if password != confirmation:
        parser.error("两次密码不同，未创建配置文件")
    try:
        write_environment(args.output, username, password)
    except (ValueError, OSError) as error:
        parser.error(str(error))
    print("已生成私密部署配置。密码原文未保存，已有配置不会被覆盖。")


if __name__ == "__main__":
    main()
