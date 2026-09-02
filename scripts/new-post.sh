#!/usr/bin/env bash
# 새 블로그 글을 카테고리 폴더에 생성합니다.
# 사용법: ./scripts/new-post.sh <카테고리> <slug> "<제목>" [tag1,tag2,...]
# 예:     ./scripts/new-post.sh ai tensorrt-int8 "TensorRT INT8 양자화 정리" "TensorRT,양자화"
#
# 카테고리(폴더): ai | backend | embedded | infra | web | cs | etc
set -euo pipefail

VALID="ai backend embedded infra web cs etc"
declare -A LABEL=( [ai]="AI/ML" [backend]="백엔드" [embedded]="임베디드" [infra]="인프라" [web]="웹" [cs]="CS" [etc]="기타" )

CAT="${1:-}"; SLUG="${2:-}"; TITLE="${3:-}"; TAGS_IN="${4:-}"
if [[ -z "$CAT" || -z "$SLUG" || -z "$TITLE" ]]; then
  echo "사용법: $0 <카테고리> <slug> \"<제목>\" [tag1,tag2,...]" >&2
  echo "카테고리: $VALID" >&2
  exit 1
fi
if [[ ! " $VALID " == *" $CAT "* ]]; then
  echo "잘못된 카테고리: '$CAT' (가능: $VALID)" >&2; exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$ROOT/content/posts/$CAT"
FILE="$DIR/$SLUG.md"
mkdir -p "$DIR"
if [[ -e "$FILE" ]]; then echo "이미 존재: $FILE" >&2; exit 1; fi

DATE="$(date +%Y-%m-%dT%H:%M:%S%:z)"   # KST 등 로컬 타임존
# 태그 배열 구성
TAGS_JSON="[]"
if [[ -n "$TAGS_IN" ]]; then
  IFS=',' read -ra T <<< "$TAGS_IN"
  TAGS_JSON="["
  for i in "${!T[@]}"; do
    tg="$(echo "${T[$i]}" | sed 's/^ *//;s/ *$//')"
    [[ $i -gt 0 ]] && TAGS_JSON+=", "
    TAGS_JSON+="\"$tg\""
  done
  TAGS_JSON+="]"
fi

cat > "$FILE" <<MD
---
title: "$TITLE"
date: $DATE
draft: false
categories: ["${LABEL[$CAT]}"]
tags: $TAGS_JSON
description: ""
ShowToc: true
---

<!-- 본문을 여기에 작성하세요. 발행 전 개인정보 점검 필수 (scripts/PRIVACY-CHECK 참고). -->
MD

echo "생성됨: $FILE"
