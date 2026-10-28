# 캔미팅 경품 선택 — 수상 건별 고유 PIN 버전

## 배포 전 필수 준비

1. `supabase/migrations/001_pin_system.sql`의 `REPLACE_ADMIN_USER_UUID` **4곳 모두** 운영자 Authentication UID로 변경한 뒤 SQL Editor에서 실행하세요. 기존 `gift_selections` 스키마와 `status` 컬럼은 앞선 관리자 버전이 준비되어 있다고 가정합니다.
2. `supabase/migrations/002_products_seed.sql`을 SQL Editor에서 실행해 `data/products.json`의 **1,022종 상품번호와 할인가**를 서버 DB에 등록합니다. JSON 가격을 변경했다면 seed SQL도 재생성해 일치시켜야 합니다.
3. Supabase CLI 설치 및 로그인/프로젝트 연결:
   ```sh
   npm install --save-dev supabase
   npx supabase login
   npx supabase link --project-ref YOUR_PROJECT_REF
   npx supabase functions deploy gift-pin-verify --no-verify-jwt
   npx supabase functions deploy gift-pin-confirm --no-verify-jwt
   ```
   위 명령어는 **이 프로젝트 폴더**에서 실행하세요. Node.js 20 이상이 필요하며, npm을 이용한 전역 설치 대신 프로젝트 의존성 및 `npx` 방식을 사용하세요. Functions의 내장 `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` 환경 변수가 제공되는지 Supabase 프로젝트에서 확인하세요. **service role key를 HTML/JS/GitHub에 넣지 마세요.**
4. `js/config.js`에 기존 프로젝트 URL, **Publishable Key**를 입력합니다.
5. GitHub Pages에는 `index.html`, `admin.html`, `data/`, `js/`를 업로드합니다. `supabase/` 폴더는 서버 소스/SQL로 Git에 저장할 수 있으나, 비밀키나 실제 PIN은 절대 포함하지 마세요.
6. `admin.html`로 로그인 → 시상별 PIN 발급 → PIN 즉시 복사 → `index.html`에서 PIN 확인 및 상품 선택 → 확정 후 관리자 선택내역 확인.

## 주의 사항

- **운영자 이메일 로그인은 admin.html에만 존재합니다.** index.html은 PIN으로 접속합니다.
- PIN은 수상 *건별* 12자리로 생성되고, DB에는 `crypt()` 해시만 저장됩니다. PIN 원문은 발급 직후 관리자 화면에서만 볼 수 있습니다.
- 브라우저에서 계산한 가격은 UI 필터용입니다. 실제 저장은 **PostgreSQL 함수가 DB 상품가격으로 다시 계산**합니다. PIN 사용 처리와 선택 저장은 동일 DB 트랜잭션으로 수행됩니다.
- PIN 재전송은 동일 `request_id`라면 중복 처리 성공 응답, 다른 요청이면 거부됩니다.
- 취소된 선택 내역은 관리자 페이지에서 취소 처리할 수 있지만 PIN은 자동으로 재사용 가능해지지 않습니다. 새 PIN을 발급하세요.
- 기존 예전 버전의 `gift_selections` 레코드는 `pin_id = null`인 상태로 남고 관리자 페이지에서 그대로 표시됩니다.
- **정책**: 기존 운영자 UID에 묶인 INSERT/SELECT/UPDATE RLS는 계속 유지됩니다. 여러 관리자 계정을 추가하려면 별도로 정책을 수정해야 합니다.
- 이 버전은 오프라인 자동 동기화를 포함하지 않습니다. 저장 실패 시 화면의 장바구니를 유지하고 동일 요청 ID로 재시도할 수 있습니다. 새로고침하면 장바구니가 사라질 수 있으므로 현장에서는 와이파이와 모바일망을 점검하세요.
- PIN 추측 공격을 억제하기 위한 프로젝트 단위 WAF/Rate limit 설정은 별도로 권장합니다. 12자리 임의 PIN은 단순 6자리보다 강하지만 시도 횟수 제한을 대신하지 않습니다.
- GitHub Pages의 `products.json`에는 **가격이 공개**되어 있습니다. 참가자 UI에는 가격을 표시하지 않지만 URL을 통해 열람할 수 있습니다. 실제 가격 비공개가 필요하면 공개 JSON에서 가격을 제거하고 서버 필터링 API를 설계해야 합니다.

## 로컬 실행 및 Git 배포

```sh
python -m http.server 5500
# http://localhost:5500/

git add index.html admin.html data/products.json js/config.js supabase README.md
git commit -m "Add per-award PIN verification and database confirmation"
git push origin main
```

Supabase에서 PIN 발급 후 브라우저가 검증 API를 불러오지 못한다면 Edge Functions 배포 상태, URL, CORS 및 Function 로그를 확인하세요.
