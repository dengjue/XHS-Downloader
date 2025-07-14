FROM python:3.12-slim

WORKDIR /app

# 元数据标签（保持不变）
LABEL name="XHS-Downloader" authors="JoeanAmier" repository="https://github.com/JoeanAmier/XHS-Downloader"

# 安装系统依赖（解决可能的网络/编译问题）
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    netcat-traditional \
    && rm -rf /var/lib/apt/lists/*

# 复制项目文件（按修改频率排序，优化构建缓存）
COPY requirements.txt /app/
COPY locale /app/locale
COPY source /app/source
COPY static/XHS-Downloader.tcss /app/static/XHS-Downloader.tcss
COPY LICENSE /app/LICENSE
COPY main.py /app/main.py

# 安装Python依赖（使用国内镜像加速，可选）
RUN pip config set global.index-url https://pypi.tuna.tsinghua.edu.cn/simple \
    && pip install --no-cache-dir -r /app/requirements.txt

# 暴露API端口（保持不变）
EXPOSE 5556

# API模式启动命令（保持不变）
CMD ["python", "main.py", "server"]