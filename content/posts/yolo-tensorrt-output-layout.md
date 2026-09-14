---
title: "YOLO를 TensorRT로 바꿨더니 검출이 0개? 출력 레이아웃 함정"
date: 2026-09-13T14:20:00+09:00
draft: false
categories: ["AI/ML"]
tags: ["YOLO", "TensorRT", "ONNX", "ultralytics", "추론최적화", "NMS"]
description: "에러도 안 나는데 검출 결과만 0개. ultralytics 버전에 따라 달라지는 ONNX 출력 레이아웃과, reshape이 조용히 성공해버리는 함정을 정리한다."
ShowToc: true
---

## 증상: 에러는 없는데 아무것도 안 잡힌다

YOLO 모델을 TensorRT 엔진으로 변환해서 추론 코드에 물렸다. 변환도 성공했고, 엔진 로드도 되고, 실행하면 프로세스가 정상적으로 돌아간다. 로그에 예외도 없다. 그런데 **검출 결과가 0개다.** 분명 화면에는 객체가 있는데 하나도 안 잡힌다.

이런 종류의 버그가 제일 고약하다. 에러가 나면 스택 트레이스라도 따라가는데, **아무 일도 안 일어난 것처럼 조용히 틀린 결과**가 나오면 어디부터 봐야 할지 막막하다.

결론부터 말하면, 원인은 **ONNX export 시 출력 텐서의 레이아웃이 바뀌었는데 후처리 코드가 옛날 레이아웃을 그대로 가정하고 있었던 것**이었다. 그리고 그 잘못된 가정이 **에러조차 내지 않고 통과**해버린 게 문제를 어렵게 만들었다.

## 배경: YOLO의 두 가지 출력 레이아웃

ultralytics로 YOLO를 ONNX로 export할 때, `nms` 옵션에 따라 출력 형태가 완전히 달라진다.

**1) raw 출력 (`nms=False`)**

```
shape: (1, 4+nc, anchors)
내용:  [cx, cy, w, h, class_score_0, class_score_1, ...]
```

NMS(Non-Maximum Suppression)가 적용되지 않은 원본 예측이다. 수천 개의 앵커마다 박스 좌표와 클래스 스코어가 들어 있고, **후처리에서 직접 스코어 필터링 + NMS를 수행**해야 최종 박스가 나온다.

**2) end2end 출력 (`nms=True`)**

```
shape: (1, N, 6)   예: (1, 300, 6)
내용:  [x1, y1, x2, y2, conf, cls]
```

NMS까지 모델 그래프 안에서 끝낸 결과다. 이미 정리된 최대 N개의 박스가 나오고, 남는 슬롯은 0으로 패딩된다. 후처리는 **conf 임계값 필터만** 걸면 된다.

이 둘은 **차원 수도, 각 축의 의미도 다르다.** 후처리 코드는 둘 중 하나를 전제로 짜여 있기 마련이다.

## 함정 1: 버전이 올라가면서 출력이 조용히 바뀐다

여기서 진짜 함정이 있었다. 같은 `nms=True` 옵션을 줘도 **ultralytics 버전에 따라 실제로 반영되는지가 달랐다.**

구버전에서는 export의 `nms` 옵션이 특정 포맷 전용이라 ONNX에는 적용되지 않는 경우가 있었다. 그래서 `nms=True`를 줘도 여전히 raw `(1, 4+nc, anchors)` 출력이 나왔다. 그런데 버전을 올리자 `nms=True`가 의도대로 동작하기 시작해, 같은 코드·같은 옵션인데 **출력이 end2end `(1, N, 6)`으로 바뀌어버렸다.**

즉, "export 스크립트도 안 건드렸는데 어느 날부터 검출이 0개가 됐다"의 배후에는 **라이브러리 업그레이드로 인한 출력 레이아웃 변경**이 있었던 것이다. 모델도 그대로, 내 코드도 그대로였지만 중간 계층의 동작이 바뀐 것.

> 교훈: export를 담당하는 라이브러리를 올릴 때는 **출력 텐서 shape이 그대로인지 반드시 확인**해야 한다. 버전 노트에 "nms export 지원"류의 변경이 있으면 특히.

## 함정 2: 틀린 reshape이 에러를 안 낸다

가장 안 잡히던 이유가 이거였다. 후처리 코드가 이렇게 되어 있었다고 하자.

```python
output = raw_output.reshape(1, 5, -1)   # (1, 4+nc, anchors)를 전제
```

원래 raw 출력을 5행(예: 좌표 4 + 클래스 1)으로 펴려는 의도다. 그런데 출력이 end2end `(1, 300, 6)`으로 바뀌면, 전체 원소 수는 `300 * 6 = 1800`개다. 그리고...

```
1800 = 5 * 360
```

**나누어떨어진다.** 그래서 `reshape(1, 5, -1)`이 **예외 없이 성공**해버린다. NumPy는 원소 총량만 맞으면 형태를 바꿔주니까, "이 데이터가 의미상 5행이 맞는가"는 따지지 않는다.

결과적으로:

- end2end 출력의 좌표값·conf·cls가 **엉뚱한 자리로 재배치**된다
- "클래스 스코어" 자리에서 읽히는 값이 대부분 패딩된 0
- 최대 스코어가 0에 가까우니 conf 필터에서 **전부 탈락**
- → 에러도 로그 이상도 없이 검출 0개

reshape이 실패해서 예외라도 났으면 30분이면 잡았을 걸, "성공한 reshape"이라 며칠을 헤맬 수 있는 함정이다.

## 원인을 어떻게 찾았나: 출력을 직접 덤프

추측으로는 못 잡는다. 결국 **엔진을 로드해서 출력 텐서의 shape과 실제 값을 그대로 찍어봤다.**

```python
# 엔진에서 나온 raw 버퍼를 아무 가정 없이 그대로 관찰
print("raw output shape:", out.shape)
print("sample values:", out.reshape(-1)[:24])
```

찍어보니 shape이 `(1, 300, 6)`이고, 앞 4개 값이 픽셀 좌표 스케일(수백 단위), 5번째 값이 0.7~0.9 구간의 confidence라는 게 바로 보였다. "아, 이건 raw가 아니라 end2end구나"가 그 순간 확정됐다. **가정을 코드에 박아두지 말고 실제 텐서를 관찰하는 것** — 이게 이런 류 버그의 유일한 지름길이다.

## 해결: 출력 shape을 읽어 후처리를 자동 분기

근본 해법은 "어떤 export로 만든 엔진이든 코드 수정 없이 동작하게" 만드는 것이다. 엔진 로드 시점에 출력 shape을 읽어두고, 그에 따라 후처리 경로를 나눈다.

```python
# 엔진 로드 후: 출력 텐서 형태로 레이아웃 판별
self.output_shape = tuple(output_binding_shape)
# (1, N, 6)이면 end2end, 아니면 raw
self.end2end = len(self.output_shape) == 3 and self.output_shape[-1] == 6

print(f"OUTPUT SHAPE: {self.output_shape} -> "
      f"{'end2end(NMS 포함)' if self.end2end else 'raw(직접 NMS)'}")
```

후처리는 이렇게 분기한다.

```python
output = raw_output.reshape(self.output_shape)

if self.end2end:
    # (1, N, 6): 이미 NMS 완료. conf 필터만.
    dets = output[0]
    keep = dets[:, 4] > conf_thres
    boxes  = dets[keep, :4]
    scores = dets[keep, 4]
    classes = dets[keep, 5]
else:
    # (1, 4+nc, A): xyxy 변환 + NMS 직접 수행
    pred = output[0].transpose(1, 0)   # (A, 4+nc)
    boxes  = pred[:, :4]
    scores = pred[:, 4:].max(axis=1)
    classes = pred[:, 4:].argmax(axis=1)
    # ... NMS ...
```

이제 시작 로그의 `OUTPUT SHAPE:` 한 줄만 보면 어느 경로를 타는지 즉시 알 수 있다. 다음에 또 export 방식이 바뀌어도 코드는 그대로 두면 된다.

## 보너스 함정: `cv2.dnn.NMSBoxes`는 xywh를 받는다

raw 경로에서 NMS를 직접 돌릴 때 또 하나 실수하기 쉬운 지점이 있다. OpenCV의 NMS 함수는 박스를 **`[x, y, w, h]` 형식으로 받는다.** xyxy(좌상단·우하단 좌표)를 그대로 넘기면, `x2`·`y2`를 너비·높이로 오해해서 박스가 실제보다 훨씬 크게 잡힌다. 그러면 IoU가 과대평가되고, 겹치지도 않은 정상 객체까지 억제되어 검출 수가 줄어든다.

```python
# xyxy -> xywh 변환 후 넘겨야 한다
boxes_xywh = np.column_stack([
    boxes_xyxy[:, 0],                      # x
    boxes_xyxy[:, 1],                      # y
    boxes_xyxy[:, 2] - boxes_xyxy[:, 0],   # w
    boxes_xyxy[:, 3] - boxes_xyxy[:, 1],   # h
])
indices = cv2.dnn.NMSBoxes(boxes_xywh.tolist(), scores.tolist(), conf, iou)
```

이것도 에러 없이 "그냥 검출이 좀 적게 되는" 형태로 나타나서, 알고 보지 않으면 모델 성능 탓으로 오해하기 쉽다.

## 정리

- YOLO의 ONNX 출력은 `nms` 옵션에 따라 **raw `(1,4+nc,A)`** 와 **end2end `(1,N,6)`** 두 가지 레이아웃이 있고, 후처리가 완전히 다르다.
- **라이브러리 버전이 올라가면 같은 옵션이라도 출력 레이아웃이 바뀔 수 있다.** export 툴 업그레이드 후엔 출력 shape을 꼭 재확인.
- 틀린 `reshape`이 **원소 수만 맞으면 조용히 성공**하기 때문에, 에러 없이 검출 0개가 되는 함정이 생긴다.
- 해결은 **가정을 박지 말고 엔진 출력 shape을 읽어 후처리를 자동 분기**하는 것. 시작 로그에 shape을 찍어두면 진단이 즉시 된다.
- `cv2.dnn.NMSBoxes`는 **xywh**를 받는다. xyxy를 그대로 주면 조용히 검출이 줄어든다.

"에러가 안 나는 버그"를 만났을 때의 교훈은 하나로 수렴한다 — **중간 산출물(여기선 엔진 출력 텐서)을 가정하지 말고 직접 찍어봐라.** 그 한 번의 `print`가 며칠을 아낀다.

다음 글에서는 이 엔진을 만드는 단계에서 겪은 **TensorRT 10/11 업그레이드 이슈**(fp16이 사라진 이유, 엔진 버전 종속성)를 정리한다.
