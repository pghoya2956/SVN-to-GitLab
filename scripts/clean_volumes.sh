#!/bin/bash

# Docker 볼륨 정리 스크립트
# 주의: 모든 데이터가 삭제됩니다!

echo "⚠️  경고: 모든 Docker 볼륨 데이터가 삭제됩니다!"
echo "계속하시겠습니까? (y/N)"
read -r response

if [[ "$response" != "y" && "$response" != "Y" ]]; then
    echo "취소되었습니다."
    exit 0
fi

echo "🧹 Docker 컨테이너 정지..."
docker compose down

echo "🗑️  볼륨 데이터 삭제..."
rm -rf docker_volumes/postgres/*
rm -rf docker_volumes/redis/*
rm -rf docker_volumes/bundle/*

echo "💥 Git 저장소 삭제 확인..."
echo "Git 저장소도 삭제하시겠습니까? (y/N)"
read -r git_response

if [[ "$git_response" == "y" || "$git_response" == "Y" ]]; then
    rm -rf git_repos/*
    echo "Git 저장소가 삭제되었습니다."
fi

echo "✅ 정리 완료!"
echo ""
echo "다시 시작하려면:"
echo "  ./scripts/init_volumes.sh"
echo "  docker compose up -d"
echo "  docker compose run --rm web rails db:create db:migrate"