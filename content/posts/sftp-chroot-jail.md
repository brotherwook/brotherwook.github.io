---
title: "[Linux] SFTP 계정을 폴더에 가두기 — chroot의 제약과 bind mount 우회"
draft: false
categories: ["인프라"]
tags: ["Linux", "SFTP", "SSH", "chroot"]
description: "SFTP 접속 계정을 특정 폴더에 격리하면서, 원하는 위치(큰 별도 디스크)에 파일을 저장하는 방법. chroot의 소유권 제약과 bind mount 우회 정리."
ShowToc: true
---

## 어쩌다 이걸 하게 됐나

외부에서 파일을 올릴 SFTP 계정을 하나 파야 했다. 요구는 세 개였다. 이 계정으로 접속하면 **지정한 폴더 안에서만** 놀게 하고, 같은 디스크의 **다른 폴더는 아예 안 보이게** 격리하고, 그러면서 파일은 용량 큰 **별도 마운트 디스크**에 쌓이게 하는 것.

"chroot 걸면 되겠지" 하고 가볍게 시작했는데.. 이게 생각보다 순순히 안 됐다. 결론부터 말하면 **chroot의 소유권 제약** 때문에 "가두기"와 "쓰기"가 정면충돌하고, 그걸 **bind mount**로 우회해야 한다. 나처럼 별도 디스크에 저장까지 얹어야 하는 상황이면 이 글이 그대로 쓸모 있을 거고, 그냥 홈 디렉토리에 쓰기만 하면 되는 경우면 뒤 절반은 안 봐도 된다.

## 핵심 제약 — 가두기와 쓰기가 충돌한다

OpenSSH의 `ChrootDirectory`에는 강한 제약이 하나 있다.

- **chroot 루트로 지정한 폴더는 반드시 `root:root` 소유 + 그룹/기타 쓰기 불가여야 한다.**
- 상위 경로 전체도 마찬가지다. 하나라도 헐거우면 접속이 즉시 끊긴다.

즉 "이 폴더에 갇히기"와 "이 폴더에 직접 쓰기"는 동시에 성립하지 않는다. 가두려고 root 소유로 만들면 정작 그 계정이 쓸 수가 없고, 쓸 수 있게 사용자 소유로 만들면 chroot가 거부한다.. 이 앞뒤 안 맞는 상황에서 한참 멈칫했다. 로그에 이게 찍히면 십중팔구 이 제약을 위반한 것이다.

```
bad ownership or modes for chroot directory
```

## 해결 구조 — 껍데기는 root, 안쪽을 bind로 연결

발상은 이렇다. chroot 루트는 **root 소유의 빈 껍데기**로 두고(제약 만족), 실제 저장 폴더를 그 안에 **bind mount**로 연결한다. 그러면 사용자에게는 한 겹 안쪽 폴더가 보이고, 파일은 내가 원하는 실제 위치에 쌓인다. 껍데기와 알맹이를 분리하는 셈이다.

예를 들어 `/data` 아래의 `store`, `app` 같은 다른 폴더는 숨기고 `upload` 폴더만 노출하고 싶다면 이렇게 짠다.

```
/data
├── store          ← 안 보임
├── app            ← 안 보임
├── sftp_root      ← chroot 루트 (빈 껍데기, root:root 755)
│   └── upload     ← 사용자에게 "/upload"로 보임 (bind → /data/upload)
└── upload         ← 실제 저장 위치 (user 소유) ★파일이 여기 쌓임
```

## 설정

계정명을 `sftpuser`, 실제 저장 폴더를 `/data/upload` 라고 하자.

```bash
# 1. 실제 저장 폴더는 사용자 소유
sudo chown sftpuser:sftpuser /data/upload
sudo chmod 755 /data/upload

# 2. chroot 루트 껍데기 (root 소유 필수)
sudo mkdir -p /data/sftp_root
sudo chown root:root /data/sftp_root
sudo chmod 755 /data/sftp_root

# 3. 껍데기 안에 마운트 지점 만들고 bind
sudo mkdir /data/sftp_root/upload
sudo mount --bind /data/upload /data/sftp_root/upload
```

여기서 놓치기 쉬운 게, 상위 경로인 `/data` 도 `root:root` + 쓰기 불가여야 한다는 점이다. chroot 루트만 신경 쓰다가 상위 폴더가 헐거워서 계속 끊기는 경우가 많다.

```bash
ls -ld /data           # drwxr-xr-x root root 확인
```

### sshd_config

`/etc/ssh/sshd_config` 하단에 추가한다. `internal-sftp` 철자에 특히 주의.. 오타 나면 접속 자체가 안 되는데 에러가 불친절해서 원인 찾기 괴롭다.

```
Subsystem sftp internal-sftp

Match User sftpuser
        ChrootDirectory /data/sftp_root
        ForceCommand internal-sftp
        AllowTcpForwarding no
        X11Forwarding no
```

기존 `Subsystem sftp /usr/lib/openssh/sftp-server` 라인은 주석 처리하거나 위처럼 교체한다.

### bind mount 영구 적용

여기까지 하고 재부팅하면 bind가 풀려서 다시 원점이 된다. 나도 처음에 이걸 깜빡하고 "잘 됐는데 왜 재부팅하니 안 되지" 했었다.. `/etc/fstab` 에 한 줄 넣어 영구 적용한다.

```bash
echo '/data/upload /data/sftp_root/upload none bind,nofail,x-systemd.requires-mounts-for=/data 0 0' \
  | sudo tee -a /etc/fstab
```

- `nofail`: bind 대상이 아직 안 올라와도 부팅을 막지 않는다.
- `x-systemd.requires-mounts-for=/data`: `/data` 가 마운트된 뒤에 bind를 실행하게 한다. 별도 디스크를 마운트해 쓰는 경우 순서가 꼬일 여지를 없애준다.
- `timeout` 류 옵션은 물리 디바이스를 기다리는 용도라 bind mount에는 불필요하다.

## 적용과 검증

```bash
sudo sshd -t                    # 설정 문법 검증 (에러 없어야 함)
sudo mount -a                   # fstab 다시 마운트 시도
sudo systemctl restart ssh
mount | grep sftp_root          # bind mount 확인
```

`sshd -t`를 restart 전에 꼭 돌려보길 권한다. 설정에 오타가 있는 채로 ssh를 restart하면 원격에서 SSH 자체가 안 열려서 곤란해질 수 있다.. 검증 먼저, 재시작은 그 다음.

## 정리

- chroot 루트는 반드시 **root 소유의 껍데기**. 상위 경로까지 전부 root 소유 + 쓰기 불가여야 한다.
- 실제 쓰기는 그 **안쪽 폴더**에서. **bind mount**로 원하는 저장 위치(큰 디스크 등)에 연결한다.
- bind는 재부팅에 안 살아남으니 **`/etc/fstab`으로 영구 적용**.
- 문제가 생기면 `sudo tail -f /var/log/auth.log` 로 원인을 바로 확인할 수 있다. `bad ownership...`이 보이면 소유권/권한 제약 위반이다.

사용자 입장에선 폴더 한 겹 더 들어가는 걸 감수하는 대신, 다른 폴더는 완전히 숨기고 원하는 디스크에 파일을 저장할 수 있다. 처음엔 "가두면서 쓰게 하라니 모순 아냐?" 싶었는데, 껍데기(chroot 루트)와 알맹이(실제 저장소)를 bind로 분리한다는 그림을 잡고 나니 의외로 단순한 구조였다.
