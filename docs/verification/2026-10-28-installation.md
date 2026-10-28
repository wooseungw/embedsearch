# 0.3.1 설치 확인 — 2026-10-28

사용자의 설치본 교체 및 GitHub 업로드 요청에 따라 버전을 0.3.1, CFBundleVersion을 4로 올렸다. 기능 코드는 직전 검증본과 동일하며 변경된 빌드 설정은 버전 메타데이터뿐이다.

- 공식 `scripts/build-app.sh`로 arm64 Release 앱을 다시 빌드했다. 기존 설치본과 같은 ad hoc 서명 방식이다.
- `/Applications/EmbedSearch.app`에 단계별로 준비한 앱을 교체했다. 기존 실행 인스턴스를 종료한 뒤 새 설치본의 실행 프로세스를 확인했다.
- 교체 전 앱, SQLite 일관성 백업, 설정 파일은 `build/install-backups/20261028-160813`에 보관했다. 백업은 GitHub에 포함하지 않는다.
- 설치된 실행 파일의 SHA-256은 검증한 빌드와 일치한다: `fb73954dabe91e09cdf6b14469e1190864369e16299b24bde1352b5da5202143`.
- `codesign --verify --deep --strict`와 설치 후 SQLite `PRAGMA quick_check`가 성공했다.
- 버전 변경 후 앱 테스트 53개를 다시 실행해 성공했다.
- GitHub에는 현재 검증한 변경 전체를 `fix/service-reliability` 브랜치와 PR로 올린다. 이 작업은 DMG 릴리스 게시나 main 병합과 구분한다.

기능·모델 평가 근거와 남은 품질 한계는 [서비스 보완 검증](2026-10-28-service-reliability.md)에 있다. 로컬 ad hoc 서명 검증은 Apple 공증이나 Sparkle 배포 설치 검증을 의미하지 않는다.
