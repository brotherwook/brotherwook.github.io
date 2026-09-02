# 블로그 자동 업데이트 워크플로우

Hugo(PaperMod) + GitHub Pages 블로그. `main` 브랜치에 push하면
GitHub Actions가 자동 빌드·배포합니다. 즉 **push = 발행**.

- 사이트: https://brotherwook.github.io/
- 글 위치: `content/posts/<카테고리>/<slug>.md`

## 카테고리(폴더)

| 폴더 | 라벨 | 내용 |
|------|------|------|
| `ai`       | AI/ML   | 딥러닝, 추론 최적화(TensorRT/YOLO), 모델 |
| `backend`  | 백엔드  | 서버/API, Python, Django |
| `embedded` | 임베디드 | Jetson, 엣지, ROS2 |
| `infra`    | 인프라  | Linux, 배포, DevOps, GPU/CUDA 환경 |
| `web`      | 웹      | 프론트엔드, Vue/Nuxt, 풀스택 |
| `cs`       | CS      | 알고리즘, 자료구조, CS 기초 |
| `etc`      | 기타    | 그 외 개발/기록 |

`categories` front matter 값은 위 라벨과 동일하게 씁니다(폴더와 taxonomy 일치).

## 새 글 만들기

```bash
./scripts/new-post.sh <카테고리> <slug> "<제목>" [tag1,tag2]
# 예: ./scripts/new-post.sh ai tensorrt-int8 "TensorRT INT8 양자화" "TensorRT,양자화"
```

front matter 예시:

```yaml
---
title: "제목"
date: 2026-09-02T19:00:00+09:00
draft: false          # false = 발행, true = 초안(비공개)
categories: ["AI/ML"]
tags: ["TensorRT"]
description: "한 줄 요약"
ShowToc: true
---
```

## 발행 전 개인정보 점검 (필수)

아래 항목이 본문/코드/이미지/파일명에 있으면 **절대 발행하지 않는다.**
애매하면 발행 전에 반드시 사용자에게 확인한다.

- [ ] 아이디, 비밀번호, API 키, 토큰, 인증서, 접속 URL/포트, 내부 IP
- [ ] 회사명(에스트래픽 / ESTraffic) 및 회사 내부 프로젝트·고객사·계약 정보
- [ ] 연봉, 소득, 급여 등 금전 정보
- [ ] 사생활(가족, 건강, 위치, 개인 일정 등)
- [ ] 실명·이메일·전화번호 등 식별 정보(공개된 GitHub 핸들은 예외)

일반적인 기술 지식(공개 문서 기반 개념·코드 예제)은 회사 맥락을 제거한
일반화된 형태로만 작성한다. 실제 사내 코드/설정은 올리지 않는다.

## 로컬 미리보기 / 빌드 확인

```bash
hugo server -D          # 초안 포함 로컬 미리보기
hugo --gc --minify      # 빌드 오류 확인(배포 전 검증)
```

## 발행

```bash
git add content/ && git commit -m "post: <제목>" && git push
```
push 후 GitHub Actions 배포 완료까지 보통 1~2분.
