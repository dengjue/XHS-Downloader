#!/bin/bash
set -e

# 核心配置项（按需修改）
APP_IMAGE="xhs-downloader"          # 应用镜像名称
BRANCH_NAME="master"                # 本地工作分支（自己fork后的分支）
API_PORT=5556                       # API服务端口
CONTAINER_NAME="xhs-downloader-app" # 容器名称
VOLUME_NAME="xhs_downloader_volume" # 数据卷名称
DOCKERFILE_PATH="Dockerfile"        # Dockerfile路径（默认当前目录）

# 检查必要工具
check_dependency() {
    if ! command -v "$1" &> /dev/null; then
        echo "错误：未安装 $1，请先安装后重试"
        exit 1
    fi
}
check_dependency "docker"
check_dependency "nc"  # 健康检查依赖
check_dependency "date"

# 检查本地文件
if [ ! -f "$DOCKERFILE_PATH" ]; then
    echo "错误：未找到Dockerfile（路径：$DOCKERFILE_PATH）"
    exit 1
fi
if [ ! -f "requirements.txt" ]; then
    echo "错误：当前目录缺少requirements.txt"
    exit 1
fi

# 检测本地依赖变更（对比工作区与最后一次提交）
check_dependency_changes() {
    echo "==== 检查本地依赖变更 ===="
    # 检查requirements.txt是否有未提交的修改
    if git diff --quiet HEAD -- requirements.txt; then
        echo "requirements.txt无变更，可复用缓存"
        return 0
    else
        echo "检测到requirements.txt本地修改，将强制重建镜像"
        return 1
    fi
}

# 清理旧镜像（保留最近3个版本）
clean_old_images() {
    echo "==== 清理旧镜像 ===="
    docker image prune -f >/dev/null 2>&1
    # 仅清理当前应用镜像的历史标签
    docker images "$APP_IMAGE" --format "{{.Tag}}" | grep "^$BRANCH_NAME-" | sort -r | tail -n +4 | while read -r tag; do
        echo "清理旧镜像: $APP_IMAGE:$tag"
        docker rmi -f "$APP_IMAGE:$tag" >/dev/null 2>&1 || true
    done
}

# 构建应用镜像
build_image() {
    echo "==== 构建本地镜像 ===="
    # 检查是否需要强制构建（依赖变更时）
    local build_args=""
    if ! check_dependency_changes; then
        build_args="--no-cache"  # 依赖变更时不使用缓存
    fi
    # 执行构建
    docker build $build_args -t "$APP_IMAGE:latest" -f "$DOCKERFILE_PATH" . || {
        echo "镜像构建失败"; exit 1;
    }
}

# 主流程
main() {
    # 1. 确保当前在目标分支（避免意外在其他分支构建）
    echo "==== 检查工作分支 ===="
    current_branch=$(git rev-parse --abbrev-ref HEAD)
    if [ "$current_branch" != "$BRANCH_NAME" ]; then
        echo "警告：当前分支为 $current_branch，非目标分支 $BRANCH_NAME"
        read -p "是否继续构建？(y/N) " confirm
        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
            echo "已取消部署"
            exit 0
        fi
    fi

    # 2. 构建镜像（基于本地修改）
    build_image

    # 3. 清理旧镜像
    clean_old_images

    # 4. 打时间戳标签（便于版本追溯）
    TIMESTAMP=$(date +%Y%m%d%H%M)
    docker tag "$APP_IMAGE:latest" "$APP_IMAGE:$BRANCH_NAME-$TIMESTAMP"
    echo "已标记镜像: $APP_IMAGE:$BRANCH_NAME-$TIMESTAMP"

    # 5. 停止并删除旧容器（修复：仅当容器存在时执行）
    echo "==== 更新容器 ===="
    if docker ps -aq -f name="$CONTAINER_NAME" >/dev/null; then  # -aq 检查所有状态的容器（包括停止的）
        echo "停止旧容器: $CONTAINER_NAME"
        docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true  # 忽略停止失败（如容器已停止）
        docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true    # 忽略删除失败
    else
        echo "无旧容器，直接创建新容器"
    fi

    # 6. 确保数据卷存在
    if ! docker volume inspect "$VOLUME_NAME" >/dev/null 2>&1; then
        echo "创建数据卷: $VOLUME_NAME"
        docker volume create "$VOLUME_NAME" >/dev/null
    fi

    # 7. 启动新容器（API模式）
    echo "==== 启动API服务 ===="
    docker run -d \
      -p "$API_PORT:$API_PORT" \
      -v "$VOLUME_NAME:/app" \
      --name "$CONTAINER_NAME" \
      --restart unless-stopped \
      --health-cmd "nc -z localhost $API_PORT || exit 1" \
      --health-interval 5s \
      --health-timeout 10s \
      --health-retries 3 \
      "$APP_IMAGE:latest"

    # 8. 等待容器就绪
    echo "==== 等待服务就绪 ===="
    for i in {1..30}; do
        status=$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "unhealthy")
        if [ "$status" = "healthy" ]; then
            break
        fi
        sleep 2
    done

    # 9. 验证部署结果
    if [ "$status" != "healthy" ]; then
        echo "部署失败！容器日志："
        docker logs "$CONTAINER_NAME"
        exit 1
    fi

    # 10. 输出成功信息
    echo "==== 部署成功 ===="
    echo "访问地址: http://localhost:$API_PORT"
    echo "本地镜像标签: $APP_IMAGE:$BRANCH_NAME-$TIMESTAMP"
    docker ps -f name="$CONTAINER_NAME" --format "容器状态: {{.Status}}"
}

# 执行主流程
main