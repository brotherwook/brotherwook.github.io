---
title: "[TensorRT] 10/11로 올리며 만난 삽질 — 사라진 --fp16, 엔진 버전 종속성, apt pin"
date: 2026-09-13T14:30:00+09:00
draft: false
categories: ["AI/ML"]
tags: ["TensorRT", "ONNX", "trtexec", "Docker", "추론최적화", "엣지"]
description: "TensorRT를 10/11 대로 올리면서 마주친 세 가지: trtexec의 --fp16이 사라진 이유, 엔진이 조용히 None으로 로드되는 버전 종속성, apt 메타패키지 pin의 함정."
ShowToc: true
---

## 들어가며

추론 최적화를 위해 TensorRT 버전을 올리는 건 흔한 일이다. 그런데 메이저 버전(10, 11)을 넘어가면 "그냥 버전만 바뀐 것"이 아니라 **동작 모델 자체가 달라지는** 지점들이 있었다. 올리는 과정에서 마주친 세 가지를 적어둔다. 셋 다 처음엔 원인이 안 보여서 한참 헤맸던 것들이라, 나중의 나(혹은 같은 삽질을 할 누군가)를 위해 남긴다.

## 1. `trtexec --fp16`이 사라졌다 — fp16은 이제 ONNX에서 결정된다

ONNX를 엔진으로 변환할 때 `trtexec --onnx=... --saveEngine=... --fp16` 식으로 fp16을 켜던 습관이 있었다. 그런데 버전을 올리고 나니 **`--fp16` 옵션이 없다**고 나온다. `--int8`, `--best` 같은 정밀도 플래그도 마찬가지.

### 왜 사라졌나 — strongly typed network

TensorRT 10부터 **strongly typed network**가 기본 모드가 됐다(11에선 사실상 유일한 모드).

- 예전 방식에서는 빌더가 정밀도를 **자유롭게 바꿀 수 있었다.** `--fp16`은 "빌더야, fp16 써도 돼"라고 **허용**하는 플래그였다. 빌더가 레이어마다 어떤 정밀도가 빠를지 판단해서 섞어 썼다.
- strongly typed에서는 빌더가 **정밀도를 임의로 안 바꾼다.** ONNX 그래프에 적힌 dtype을 **그대로** 따른다.
- 그러니 "빌더에게 허용한다"는 의미의 `--fp16`은 존재 이유가 없어졌고, 그래서 제거됐다.

### 그럼 fp16 엔진은 어떻게 만드나

**ONNX 자체를 fp16으로 export**하면 된다. 정밀도 결정 시점이 "엔진 빌드"에서 "ONNX export"로 앞당겨진 것.

```python
# export 시점에 정밀도를 결정한다. half=True면 fp16 ONNX가 나온다.
model.export(format="onnx", imgsz=IMG_SIZE, half=True,
             dynamic=False, simplify=True, opset=12, nms=True)
```

```bash
# trtexec에서는 --fp16을 뺀다. ONNX의 dtype을 그대로 따른다.
trtexec --onnx=model.onnx --saveEngine=model.engine
```

바뀌고 나서 오히려 좋아진 점.. 변환 스크립트와 런타임이 **정밀도에 무관**해진다. `trtexec`는 ONNX dtype을 그대로 따르니 fp16이든 fp32든 같은 명령으로 변환되고, 런타임도 엔진에서 dtype을 읽어(`trt.nptype(get_tensor_dtype(name))`) 버퍼를 할당하면 분기 없이 돈다. **정밀도를 바꾸고 싶으면 export의 `half`만 고치고 다시 만들면 끝**이다.

## 2. 엔진이 조용히 `None`으로 로드된다 — 버전 종속성

다른 환경에 배포했더니 이런 에러가 났다.

```
'NoneType' object has no attribute 'create_execution_context'
```

`create_execution_context`를 호출하는 객체가 `None`이라는 건, 그 앞 단계인 `deserialize_cuda_engine()`이 **엔진 객체 대신 `None`을 돌려줬다**는 뜻이다. 그런데 예외를 던지는 게 아니라 **조용히 `None`을 반환**하니 원인이 한눈에 안 보인다.. 이런 게 제일 짜증난다.

### 원인 — 엔진 플랜은 빌드한 TRT 버전에 종속된다

TensorRT 엔진(플랜) 파일은 **범용 포맷이 아니다.** 그걸 빌드한 TensorRT 버전에 종속되고, **로드하는 쪽 버전이 다르면 deserialize가 실패**한다. 그리고 그 실패가 예외가 아니라 `None` 반환으로 나타난다.

특히 헷갈렸던 건, 버전이 **세 군데**에서 어긋날 수 있다는 점이었다.

| 어디 | 무엇 |
|---|---|
| 엔진 파일 | 어떤 TRT 버전으로 **빌드**됐는가 |
| 실행 컨테이너/환경 | 어떤 TRT 버전이 **설치**돼 있는가 |
| 배포 번들이 싣고 있는 `.so` | 패키징 도구가 함께 묶은 `libnvinfer.so.*` 버전 |

특히 세 번째가 함정이었다. 실행 파일을 standalone으로 패키징하는 도구(예: Nuitka/PyInstaller류)는 의존 라이브러리를 함께 번들하는데, 그 번들의 `RPATH`가 `$ORIGIN`으로 잡히면 **번들 안의 `.so`가 시스템에 설치된 것보다 우선 로드**된다. 즉 컨테이너에 올바른 TRT를 깔아놨어도, 번들이 다른 버전을 싣고 있으면 그쪽이 이긴다.

### 엔진 파일의 빌드 버전 확인법

플랜 파일 헤더에 빌드 버전이 박혀 있어서, 바이너리를 직접 들여다보면 확인할 수 있다.

```bash
# 플랜 헤더 오프셋 0x18 부근에 버전 바이트가 있다
xxd -s 0x18 -l 4 model.engine
# 예: 0b 02 01 02  -> 11.2.1.2
```

### 해결 원칙

교훈은 단순하다. **엔진 생성 · (번들 빌드) · 실행을 모두 같은 TensorRT 버전에서 하라.** 특히 standalone 번들을 쓴다면 엔진/번들/실행환경 **세 곳의 TRT 버전이 반드시 일치**해야 한다. 버전을 올릴 땐 엔진을 반드시 **재생성**하는 걸 체크리스트에 박아두는 게 안전하다.

## 3. apt 메타패키지만 pin하면 소용없다

Docker 이미지에서 특정 TensorRT 버전을 설치하려고 메타패키지에 버전을 붙였다.

```dockerfile
apt-get install -y tensorrt=10.8.0.43-1+cuda12.8
```

그런데 빌드가 이렇게 깨진다.

```
tensorrt : Depends: libnvinfer10 (= 10.8.0.43-...) but 10.16.x is to be installed
           Depends: libnvinfer-bin (= 10.8.0.43-...) but 11.2.x is to be installed
           ...
E: Unable to correct problems, you have held broken packages.
```

### 원인 — 하위 패키지가 최신으로 끌려간다

CUDA 베이스 이미지에는 **NVIDIA 공식 apt 저장소가 이미 등록**돼 있고, 거기엔 더 높은 버전의 TensorRT 패키지들이 있다. `tensorrt` **메타패키지에만** 버전을 고정하면, apt는 그 하위 의존 패키지(`libnvinfer10`, `libnvinfer-bin` 등)를 여전히 저장소의 **최신 버전**으로 고르려 한다. 그 결과 메타패키지의 `=` 제약과 충돌해서 "held broken packages"가 된다.

에러 맨 끝에 뜨는 `libnvinfer-samples ... not going to be installed`는 **증상이지 원인이 아니다.** 마지막 줄만 보고 그 패키지를 따로 설치하려 들면 헤맨다. 전체 에러를 보면 여러 하위 패키지가 다 최신으로 끌려가고 있음이 보인다.

### 해결 — apt preferences(pin)로 관련 패키지 전체를 고정

메타패키지 하나가 아니라 **TensorRT 관련 패키지 전체**를 pin으로 묶어야 한다.

```dockerfile
# 로컬 repo .deb 등록 후
RUN printf 'Package: tensorrt* libnvinfer* libnvonnxparsers* python3-libnvinfer*\nPin: version 10.8.0.43-1+cuda12.8\nPin-Priority: 1001\n' \
        > /etc/apt/preferences.d/tensorrt \
    && apt-get update \
    && apt-get install -y tensorrt python3-libnvinfer-dev
```

- 와일드카드(`libnvinfer*` 등)로 **하위 패키지까지 전부** 같은 버전으로 고정
- `Pin-Priority: 1001` — 다운그레이드까지 허용하는 최우선 순위
- pin 파일이 이미지에 남으니 **이후 `apt upgrade`로 TRT가 올라가는 것도 방지**된다
- 파이썬 바인딩은 `python3-libnvinfer-dev`로 들어오므로 별도 `pip install tensorrt`가 필요 없다

검증은 실제 설치 전에 시뮬레이션으로 해두는 걸 추천한다.

```bash
apt-get install -s tensorrt   # -s: 실제 설치 없이 해소 결과만 확인
```

모든 `libnvinfer*` 패키지의 candidate가 목표 버전으로 잡히는지 확인하고 나서 실제 빌드에 들어가면, 이미지 한 번 빌드하는 데 드는 시간을 아낄 수 있다.

## 정리 — TensorRT 메이저 버전 올릴 때 체크리스트

1. **정밀도**: `trtexec --fp16`은 없어졌다. fp16은 **ONNX export 시점**(`half=True`)에 결정한다. (strongly typed network 때문)
2. **엔진 재생성**: 엔진 플랜은 빌드한 TRT 버전에 종속된다. 버전 올리면 **엔진을 반드시 다시 만든다.** 안 맞으면 `deserialize`가 조용히 `None`.
3. **번들 주의**: standalone 패키징을 쓰면 번들의 `.so`가 `RPATH=$ORIGIN`으로 우선 로드된다. **엔진 / 번들 / 실행환경 세 곳의 TRT 버전 일치**를 확인.
4. **apt pin**: 메타패키지만 고정하면 하위 패키지가 최신으로 끌려간다. `libnvinfer*` 등 **관련 패키지 전체를 pin**한다.
5. **실제 버전 확인**: `dpkg -l | grep libnvinfer`, `trtexec --help | head -1`, 엔진은 `xxd -s 0x18 -l 4`로 교차 확인.

메이저 버전 업그레이드는 "숫자만 바뀌는 일"이 아니라 빌더의 동작 방식, 아티팩트의 호환성, 패키지 의존성이 같이 움직이는 일이었다. 이 다섯 개만 미리 체크했어도 며칠은 아꼈을 것 같아서.. 기록으로 남긴다.
