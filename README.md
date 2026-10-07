# Space Tree

macOS용 가벼운 파일 용량 분석기. 폴더를 선택하면 전체 하위 파일을 스캔하고 용량에 비례하는 트리맵으로 표시합니다. Finder나 다른 앱에서 파일이 바뀌면 자동 갱신합니다.

## 설치

macOS 13 이상에서 [최신 릴리스](https://github.com/DIMBD-AKE/Space-Tree/releases/latest)의 DMG를 다운로드하고 `Space Tree.app`을 `Applications`로 옮기세요. 배포 앱은 Apple Silicon과 Intel을 모두 지원하며 Developer ID 서명과 Apple 공증을 거칩니다.

## 소스에서 실행

macOS 13 이상과 Xcode Command Line Tools가 필요합니다. 외부 패키지는 사용하지 않습니다.

```sh
bash scripts/build-app.sh
open "dist/Space Tree.app"
```

생성된 `.app`은 Finder에서 더블 클릭하거나 응용 프로그램 폴더로 옮겨 사용할 수 있습니다. 현재 Mac의 아키텍처로 빌드합니다. 설치된 Developer ID Application 또는 Apple Development 인증서로 서명하여 빌드마다 앱의 권한 식별자가 바뀌지 않게 합니다. `SPACETREE_SIGNING_IDENTITY`로 인증서를 지정할 수 있습니다. 인증서가 없으면 임시 서명을 사용하며 다시 빌드한 뒤 권한 재설정이 필요할 수 있습니다.

## 로컬 릴리스 빌드

GitHub Actions를 사용하지 않습니다. Keychain의 Developer ID Application 인증서와 공증 자격 증명으로 로컬에서 Universal 앱과 DMG를 빌드·서명·공증합니다. Hardened Runtime과 타임스탬프를 적용하고 앱과 DMG 모두 공증 티켓을 붙여 검증합니다.

```sh
SPACETREE_NOTARY_PROFILE=공증용-Keychain-프로필 bash scripts/build-release.sh
```

Keychain 프로필 대신 `SPACETREE_NOTARY_KEY`에 API 키 파일 경로, `SPACETREE_NOTARY_KEY_ID`에 키 ID, 팀 API 키라면 `SPACETREE_NOTARY_ISSUER`에 Issuer ID를 지정할 수 있습니다. 키 파일과 자격 증명은 저장소에 넣지 마세요. 결과는 `dist/Space-Tree-1.0.1-universal.dmg`과 `dist/SHA256SUMS.txt`입니다.

## 사용

- 트리맵의 폴더를 클릭하면 내부로 진입합니다. 파일을 클릭하면 상세 정보를 표시합니다.
- 오른쪽 전체 목록에서는 폴더를 더블 클릭하거나 선택 후 Return을 누릅니다.
- 경로 버튼 또는 `⌘↑`로 상위 폴더로 이동합니다. `⌘O`로 새 폴더를 엽니다.
- `⌘R`은 전체 재스캔, `⇧⌘R`은 선택한 항목을 Finder에 표시합니다.
- 스캔 중지는 자동 추적도 멈춥니다. 새로 고침하면 전체를 재스캔하고 추적을 재개합니다.
- 이름 검색은 현재 폴더의 항목을 검색합니다. 용량순 목록은 모든 항목을 유지합니다.
- 기본 면적은 파일 크기입니다. 할당 크기 기준으로 전환할 수 있습니다.
- 첫 분석이 끝나기 전에도 폴더를 탐색할 수 있습니다. 진행 중인 폴더의 내용과 용량을 약 0.5초 간격을 목표로 갱신합니다. 아직 합산 중인 용량은 `부분 결과`와 `…`, 대기 중인 폴더는 `분석 중`으로 표시합니다. 파일시스템 응답이 지연되면 갱신 간격도 길어질 수 있습니다.
- 자동 갱신이나 전체 새로 고침 중에는 기존 트리맵과 탐색 위치, 선택 항목, 검색어를 유지합니다. 분석이 완료되면 새 결과로 교체하며, 진행 상황은 하단에 표시합니다.
- Finder 버튼은 상단 경로 오른쪽에 있습니다. `디스크 전체 사용`은 OS가 보고한 사용량이며 선택 폴더의 합계와 구분합니다.

처음 분석하기 전에 전체 디스크 접근 설정을 안내합니다. macOS 시스템 설정에서 Space Tree에 한 번 허용하고 필요하면 앱을 재실행하세요. 휴지통 접근 확인을 통과하면 다음 실행부터 안내를 생략합니다. 나중에는 탐색 메뉴의 `전체 디스크 접근 설정…`으로 다시 열 수 있습니다. 이 권한을 허용해도 다른 사용자의 접근 제한이나 시스템 보호는 유지됩니다.

숨김 파일과 `.app` 같은 패키지 내부를 포함합니다. 심볼릭 링크는 따라가지 않습니다. 접근할 수 없는 항목은 경고와 함께 집계에서 제외됩니다. 시작 화면의 `디스크`는 `/System/Volumes/Data`를 분석하며 `/`를 선택해도 같은 경로를 사용합니다. 다른 마운트 볼륨은 중복 합산하지 않고 별도로 열어 분석합니다.

할당 크기는 파일마다 보고된 블록 사용량의 합계입니다. 하드 링크는 경로마다 합산하며, APFS 클론·공유 블록·스냅샷·압축 때문에 실제 회수 가능한 공간과 다를 수 있습니다. 클라우드 파일은 메타데이터만 조회하고 내용을 다운로드하지 않습니다.

변경 감시는 macOS FSEvents를 사용합니다. 스캔 전에 감시를 시작하고, 이벤트를 모아 변경 하위 트리만 재스캔합니다. 이벤트 유실·볼륨 변경 시 전체 재스캔합니다. 선택한 루트가 이동하면 열린 디렉터리 핸들로 새 위치를 추적합니다. 읽기 오류 시 마지막 스냅샷과 오류 상태를 표시합니다. 일부 네트워크 파일시스템은 로컬 FSEvents를 제공하지 않을 수 있으므로 수동 새로 고침을 사용할 수 있습니다.

트리맵은 최대 1,200개 셀을 그리며 작은 항목은 하나로 묶습니다. 빈 파일과 모든 작은 항목은 가상화된 전체 목록에서 확인할 수 있습니다. 스캔을 실행하지 않는 동안 폴링 타이머를 사용하지 않습니다.

## 검증과 성능

```sh
swift test
swift build -c release
.build/release/SpaceTree --benchmark --files 50000 --runs 5
.build/release/SpaceTree --benchmark --files 100000 --runs 5
.build/release/SpaceTree --benchmark --path /Applications/Xcode.app --runs 5 --skip-baseline
.build/release/SpaceTree --benchmark --path /분석할/폴더 --parallelism 1 --single-pass
.build/release/SpaceTree --benchmark --path /분석할/폴더 --parallelism 4 --single-pass
.build/release/SpaceTree --benchmark --path /System/Volumes/Data --single-pass --observe-progress
```

생성 fixture는 100개 폴더에 파일을 분산하며 데이터 기록 없이 희소 파일 길이만 설정합니다. 내용 전송 성능이 아닌 메타데이터 탐색 성능을 측정합니다. 기본적으로 측정 후 fixture를 제거합니다. `--keep-fixture`를 사용하면 출력 JSON의 `path`에 남겨 재측정할 수 있습니다. `--path`로 지정한 경로의 파일은 변경하지 않습니다. `--single-pass`는 반복·기준 구현·레이아웃 측정을 생략하고 전체 분석 한 번과 상위 폴더 합계를 출력합니다.

자세한 측정 조건과 결과는 [성능 보고서](docs/performance.md)에 기록합니다. 스캐너의 `Scan` signpost를 Instruments에서 확인할 수 있습니다.

기술 근거: [Apple FSEvents 가이드](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html), [Apple fts(3) 문서](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/fts.3.html).
