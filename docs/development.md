# 개발 및 로컬 배포

macOS 13 이상과 Xcode Command Line Tools가 필요합니다. 외부 패키지는 사용하지 않습니다.

## 소스에서 실행

```sh
bash scripts/build-app.sh
open "dist/Space Tree.app"
```

현재 Mac의 아키텍처로 빌드합니다. 설치된 Developer ID Application 또는 Apple Development 인증서로 서명하며, `SPACETREE_SIGNING_IDENTITY`로 인증서를 지정할 수 있습니다. 인증서가 없으면 임시 서명을 사용하므로 빌드 후 파일 접근 권한을 다시 설정해야 할 수 있습니다.

## 테스트와 벤치마크

```sh
swift test
swift build -c release
.build/release/SpaceTree --benchmark --files 50000 --runs 5
.build/release/SpaceTree --benchmark --path /Applications/Xcode.app --runs 5 --skip-baseline
.build/release/SpaceTree --benchmark --path /System/Volumes/Data --parallelism 4 --single-pass --observe-progress
```

생성 데이터는 100개 폴더에 희소 파일을 분산하며, 파일 내용 전송 대신 메타데이터 탐색 성능을 측정합니다. 기본적으로 측정 후 제거하고, `--keep-fixture`를 지정하면 유지합니다. `--path`로 지정한 기존 파일은 변경하지 않습니다.

`--single-pass`는 전체 분석 한 번과 상위 폴더 합계를 출력합니다. `--observe-progress`는 초기 화면처럼 부분 결과 생성도 포함하며 전달 시각·용량·대기 폴더 수를 기록합니다. `--parallelism`은 1~4입니다. 반복 실행에는 OS 메타데이터 캐시가 적용되므로 콜드 디스크 성능으로 해석하지 않습니다.

자세한 조건과 원본 집계는 [성능 보고서](performance.md)에 있습니다. Instruments에서는 스캐너의 `Scan` signpost를 확인할 수 있습니다.

## 릴리스 빌드

GitHub Actions 없이 로컬에서 Universal 앱과 DMG를 빌드합니다. Keychain의 Developer ID Application 인증서와 공증 자격 증명이 필요합니다.

```sh
SPACETREE_NOTARY_PROFILE=공증용-Keychain-프로필 bash scripts/build-release.sh
```

앱과 DMG에 Hardened Runtime·타임스탬프·Developer ID 서명·Apple 공증을 적용하고, 공증 티켓과 Gatekeeper 검사를 검증합니다. 결과는 `dist/Space-Tree-<버전>-universal.dmg`과 `dist/SHA256SUMS.txt`입니다. 버전은 `scripts/build-app.sh`에서 관리합니다.

Keychain 프로필 대신 `SPACETREE_NOTARY_KEY`에 API 키 경로, `SPACETREE_NOTARY_KEY_ID`에 키 ID, 팀 API 키라면 `SPACETREE_NOTARY_ISSUER`에 Issuer ID를 지정할 수 있습니다. 키 파일·인증서·비밀번호는 저장소에 포함하지 않습니다.
