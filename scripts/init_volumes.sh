#!/bin/bash

# Docker 볼륨 초기화 스크립트
# PostgreSQL과 Redis 데이터를 로컬에서 관리하기 위한 설정

echo "🚀 Docker 볼륨 초기화 시작..."

# 색상 정의
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# 볼륨 디렉토리 생성
echo "📁 볼륨 디렉토리 생성 중..."
mkdir -p docker_volumes/{postgres,redis,bundle}
mkdir -p git_repos

# PostgreSQL 권한 설정 (UID 999는 postgres 컨테이너의 기본 사용자)
echo "🔐 PostgreSQL 권한 설정..."
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS에서는 권한 설정 불필요 (Docker Desktop이 처리)
    echo -e "${YELLOW}ℹ️  macOS 환경 - PostgreSQL 권한 자동 처리${NC}"
else
    # Linux에서는 postgres 사용자 권한 필요
    sudo chown -R 999:999 docker_volumes/postgres
    echo -e "${GREEN}✅ PostgreSQL 권한 설정 완료${NC}"
fi

# Redis 권한 설정
echo "🔐 Redis 권한 설정..."
chmod 755 docker_volumes/redis

# Bundle 캐시 권한
echo "💎 Bundle 캐시 권한 설정..."
chmod 755 docker_volumes/bundle

# Git repos 권한
echo "📦 Git 저장소 권한 설정..."
chmod 755 git_repos

# 상태 확인
echo ""
echo "📊 디렉토리 구조:"
tree -L 2 docker_volumes git_repos 2>/dev/null || {
    echo "docker_volumes/"
    echo "├── postgres/"
    echo "├── redis/"
    echo "└── bundle/"
    echo "git_repos/"
}

echo ""
echo -e "${GREEN}✅ 볼륨 초기화 완료!${NC}"
echo ""
echo "다음 명령으로 서비스를 시작하세요:"
echo "  docker compose up -d"
echo ""
echo "첫 실행이라면 데이터베이스를 생성하세요:"
echo "  docker compose run --rm web rails db:create db:migrate"