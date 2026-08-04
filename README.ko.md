# NewsBar

> 조용한 macOS 메뉴 바 뉴스 애그리게이터 — 웨이보(Weibo) 트렌드, 빌리빌리(Bilibili) 트렌드, 커스텀 RSS 피드를 한눈에.

<p align="center">
  <strong>🌐 언어</strong> ·
  <a href="README.md">English</a> ·
  <a href="README.zh-CN.md">简体中文</a> ·
  <a href="README.zh-TW.md">繁體中文</a> ·
  <a href="README.ja.md">日本語</a> ·
  <a href="#-언어">한국어</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Swift-5.9-orange" alt="Swift 5.9">
  <img src="https://img.shields.io/badge/macOS-15.0%2B-blue" alt="macOS 15.0+">
  <img src="https://img.shields.io/badge/License-MIT-green" alt="MIT License">
  <img src="https://img.shields.io/badge/Platforms-macOS-lightgrey" alt="Platforms: macOS">
</p>

**NewsBar**는 SwiftUI로 제작된 **네이티브 macOS 메뉴 바 / 상태 바 뉴스 앱**입니다. **웨이보(Weibo) 트렌드**, **빌리빌리(Bilibili) 트렌드**, 그리고 **사용자 자신의 RSS 피드**를 조용하고 한눈에 보이는 메뉴 바 패널에 모아줍니다. 선택적 **AI 요약**이 하루의 정보 소음을 출처가 명시된 정독 브리핑으로 바꿔줍니다.

의존성 제로. 순수 Swift. 무료·오픈소스(MIT).

---

## ✨ 기능

- **🔥 Weibo 트렌드** — 실시간 웨이보 인기 검색 토픽
- **📺 Bilibili 트렌드** — 빌리빌리 인기·트렌드 콘텐츠
- **📡 커스텀 RSS 피드** — 원하는 RSS/Atom 소스 추가, 완전히 확장 가능
- **🤖 AI 요약** — Popup과 Dashboard에서 공유되는 2개 카테고리 브리핑(트렌드 개요 / 데일리 에센셜). 출처가 있는 행을 클릭하면 원문이 열립니다. **2단계 스마트 트리거**: 보통은 "마지막 요약 이후 ≥ 1시간"을 기준으로 하며, 웨이보에 '폭(爆)' 라벨 토픽이 나타나면 **즉시 요약을 생성**하고 그 폭 라벨 토픽을【트렌드 개요】에 우선 표시합니다. 폭 라벨 요약은 15분에 1회로 제한됩니다.
- **📊 에디토리얼 대시보드** — 반응형 헤더, 공유 AI 브리핑, 재설계된 트렌드 카드, 개별 새로고침이 있는 소스별 RSS 레이아웃
- **⏱ 적응형 스마트 새로고침** — 시작 시 페치 + 가시성 기반 트렌드 폴링 + 적응형 RSS 간격
- **🔄 자동 업데이트** — GitHub Releases 확인, 원클릭 다운로드
- **🔐 안전한 저장** — API 키는 AES-256-GCM으로 암호화되어 기기에 귀속
- **📰 레트로 신문 테마** — 선택 가능한 1960년대 에디토리얼 디자인: 종이 질감, 벽돌색 포인트, 사각 클리핑 카드, 인쇄풍 소스 마크
- **🪟 모던 머티리얼 테마** — 네이티브 SwiftUI 머티리얼 외관과 명확한 에디토리얼 페이지 헤더
- **🌓 다크 모드** — 라이트 / 다크 / 시스템 자동, 실시간 전환
- **📦 의존성 제로** — 순수 Swift, 서드파티 라이브러리 없음

---

## 📦 설치

[Releases](../../releases)에서 최신 DMG를 다운로드하고 **Applications**에 드래그하세요.

> **macOS 15.0+** 필요

## 🚀 사용법

1. **메뉴 바 아이콘**을 클릭하여 뉴스 패널 열기
2. 아무 뉴스 항목을 클릭하여 브라우저에서 열기
3. **출처가 있는 AI 요약 행**은 상주 소스 배지를 표시하며, 클릭하면 원문 열기
4. 상단의 **업데이트 확인**을 클릭하여 새 버전 수동 확인
5. 하단의 ⚙️를 클릭하여 설정 열기, RSS 소스와 AI 구성
6. 📊를 클릭하여 **Dashboard** 열기: 인기 트렌드 카드, AI 브리핑 패널, 고정 2열 그리드의 소스별 RSS 영역
7. 「설정 → 일반 → 테마」에서 **모던 머티리얼** 또는 **레트로 신문** 테마 전환
8. 설정 패널 하단에서 종료

> Popup과 Dashboard는 전역 새로고침 후 생성된 하나의 상세 AI 브리핑을 공유합니다. Popup은 카테고리당 최대 2행, Dashboard는 전체 결과를 표시합니다. Dashboard에는 독립적인 AI 새로고침 버튼도 있습니다.

---

## 🤖 AI 요약 활성화

설정 → **AI** 탭: 공급자를 선택하고 API 키를 입력하세요. 지원 공급자: **DeepSeek**, **MiniMax**, **Opencode Go/Zen**, **Google AI Studio**, **Ollama Cloud**, 그리고 **사용자 정의 공급자**(엔드포인트, 모델 ID, 인증 헤더).

Popup과 Dashboard는 요약 길이 프리셋(기본 360자)과 일일 요청 상한(기본 50, 20/50/100 선택)을 공유합니다. 자동 요약은 12/24시간 트렌드 히스토리를 사용하며, 의미 있는 변화와 쿨다운 조건이 충족될 때만 재생성합니다. Dashboard의 AI 버튼으로 강제 독립 재생성도 가능합니다.

### 지원 AI 공급자

| Provider | Endpoint | Models |
|---|---|---|
| DeepSeek | api.deepseek.com | deepseek-v4-flash, deepseek-v4-pro |
| MiniMax | api.minimaxi.com | MiniMax-M3, MiniMax-M2.7, MiniMax-M2.7-highspeed, MiniMax-M2.5, MiniMax-M2.5-highspeed, MiniMax-M2.1, MiniMax-M2.1-highspeed, MiniMax-M2 |
| Opencode Go | open-code-go.aiizhi.com | deepseek-v4-flash, deepseek-v4-pro |
| Opencode Zen | open-code-zen.aiizhi.com | deepseek-v4-flash, deepseek-v4-pro |
| Google AI Studio | generativelanguage.googleapis.com | gemini-3.6-flash, gemini-3.5-flash, gemini-3.5-flash-lite, gemini-3.1-flash-lite, gemini-3.1-pro-preview, gemini-3-flash-preview, gemini-2.5-pro, gemini-2.5-flash, gemini-2.5-flash-lite |
| Ollama Cloud | ollama.com | deepseek-v4-flash:cloud, deepseek-v4-pro:cloud, gpt-oss:20b-cloud, gpt-oss:120b-cloud, kimi-k3:cloud, minimax-m3:cloud, ... |
| Custom | 사용자 정의 | 커스텀 엔드포인트 / 모델 ID |

> **모델 접기**: 기본적으로 각 공급자의 DeepSeek 계열 모델만 표시됩니다(있는 경우). 「일반 → 개발자 옵션」에서「모든 AI 모델 표시」를 활성화하면 전체 공식 모델을 볼 수 있습니다.

---

## 🛠 개발

```bash
# 빌드
swift build -c release --arch arm64

# 또는 공식 패키징 스크립트(App + DMG 빌드)
bash scripts/build.sh
```

### 릴리스 절차

```bash
# 1. 먼저 release/vX.Y.Z에서 version.txt와 RELEASE_NOTES.md를 업데이트
swift test                    # 전체 테스트 스위트 실행
bash scripts/build.sh         # 공식 App 및 DMG 패키징
# 2. main에 PR을 올리고, 필요한 CI가 통과할 때까지 기다린 후 병합
git tag -a vX.Y.Z -m "vX.Y.Z — summary"
git push origin vX.Y.Z
bash scripts/release.sh       # GitHub Release + DMG/SHA256 업로드
```

PR·CI·병합·태그·검증의 전체 워크플로는 [docs/release-conventions.md](docs/release-conventions.md)를 참조하세요.

---

## 📂 프로젝트 구조

```text
Sources/NewsBar/
├── main.swift              # 진입점, 단일 인스턴스 체크
├── AppDelegate.swift       # 상태 바, popover, 창 관리
├── Models/
│   ├── AIProvider.swift        # 멀티 공급자 AI 정의
│   ├── NewsItem.swift          # 뉴스 항목 모델(웨이보 핫 라벨 포함)
│   ├── NewsSource.swift        # 소스 열거(Weibo/Bilibili/RSS)
│   ├── AppSettings.swift       # 사용자 설정(Observable)
│   ├── CacheEntry.swift        # 캐시 항목
│   └── UpdateInfo.swift        # Release/버전 모델
├── Services/
│   ├── NewsOrchestrator.swift  # 핵심 코디네이터: 새로고침·캐시·공유 AI 상태 머신
│   ├── UpdateChecker.swift     # GitHub 업데이트 체크 + DMG 다운로드
│   ├── WeiboHotService.swift   # 웨이보 트렌드 페처
│   ├── BilibiliHotService.swift# 빌리빌리 트렌드 페처
│   ├── RSSService.swift        # RSS/Atom 파서
│   ├── AISummaryService.swift  # AI 요약(멀티 공급자)
│   ├── CacheManager.swift      # 파일 캐시(actor)
│   ├── KeychainManager.swift   # 더 이상 사용 안 함 — 1회성 마이그레이션 전용
│   ├── EncryptedKeyStore.swift # AES-256-GCM 암호화 파일 저장
│   ├── RateLimiter.swift       # 속도 제한기(actor)
│   ├── RefreshLog.swift        # 새로고침 로그(actor, 링 버퍼)
│   └── SecurityPolicies.swift  # URL/샌나이즈/XML 안전
├── Views/
│   ├── MenuBar/                # 재사용 popover 컴포넌트, 컴팩트 공유 AI 브리핑
│   ├── Settings/               # 설정 창 탭
│   ├── Dashboard/              # Dashboard 창, 전체 AI 브리핑 + 소스별 새로고침
│   └── Theme/                  # 모던 머티리얼 / 레트로 신문 프리미티브
└── Extensions/
    ├── URLOpener.swift          # 안전한 URL 열기
    └── View+Glass.swift         # 유리 효과 + 적응형 색상
```

---

## ⚙️ 기술 스택

- **Swift 5.9** + **SwiftUI** (macOS 15.0+)
- **AppKit**: NSStatusBar, NSPopover
- **AI APIs**: DeepSeek / MiniMax / Opencode / Google AI Studio / Ollama Cloud / 커스텀
- **저장**: 암호화 파일(AES-256-GCM, CryptoKit), UserDefaults, 파일 캐시(actor)
- **외부 의존성 제로**

---

## 🔍 키워드

`macOS 메뉴 바 앱` · `상태 바 앱` · `메뉴 바 뉴스` · `뉴스 애그리게이터` · `SwiftUI` · `Swift` · `네이티브 macOS 앱` · `AI 요약` · `웨이보 트렌드` · `빌리빌리 트렌드` · `RSS 리더` · `RSS 애그리게이터` · `트렌드 토픽` · `DeepSeek` · `Gemini` · `MiniMax` · `Ollama` · `메뉴 바` · `오픈소스`

---

## 🔗 관련 링크

- [Releases](../../releases)
- [웨이보 트렌드 API](https://s.weibo.com)
- [빌리빌리 트렌드 API](https://www.bilibili.com)
- [DeepSeek Platform](https://platform.deepseek.com)
- [MiniMax Platform](https://platform.minimaxi.com)
- [Google AI Studio](https://aistudio.google.com)
- [Ollama Cloud](https://ollama.com)

---

## 📄 라이선스

MIT © 2024-2026 [blackkcold](https://github.com/blackkcold) and contributors.
자세한 내용은 [LICENSE](LICENSE)를 참조하세요.

---

## 🌐 언어

- [English](README.md)
- [简体中文](README.zh-CN.md)
- [繁體中文](README.zh-TW.md)
- [日本語](README.ja.md)
- **한국어** — 이 파일
