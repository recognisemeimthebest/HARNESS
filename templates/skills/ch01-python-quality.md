# Python 코드 품질 가이드

> 모든 Python 코드 작성/수정 시 참고하는 메타 스킬.

---

## 에러 처리 원칙

1. **외부 호출은 반드시 try-except**: API, DB, 파일 I/O
2. **구체적 예외 잡기**: `except Exception` 금지 → `except ValueError`, `except httpx.HTTPError` 등
3. **에러 로깅**: `logging.error()` 사용, `print()` 금지
4. **사용자 메시지**: 내부 에러를 그대로 노출하지 않기

```python
# 좋은 예
try:
    response = await client.get(url, timeout=10)
    response.raise_for_status()
except httpx.TimeoutException:
    logging.warning(f"Timeout: {url}")
    return fallback_value
except httpx.HTTPStatusError as e:
    logging.error(f"HTTP {e.response.status_code}: {url}")
    raise
```

## 보안 체크리스트

- [ ] 토큰/키/비밀번호 → `.env` + `os.environ`, 코드에 절대 하드코딩 금지
- [ ] 사용자 입력 → 검증 후 사용 (길이 제한, 타입 체크, 특수문자 이스케이프)
- [ ] SQL → parameterized query 사용, f-string 금지
- [ ] HTTP → HTTPS 사용 (민감 데이터)
- [ ] 디버그 코드 → 배포 전 제거 (`breakpoint()`, `print("debug")`)

## async 패턴

```python
# 나쁜 예: async 안에서 동기 블로킹
async def fetch_data():
    response = requests.get(url)      # 블로킹!
    time.sleep(1)                      # 블로킹!

# 좋은 예: 비동기 라이브러리 사용
async def fetch_data():
    async with httpx.AsyncClient() as client:
        response = await client.get(url)
    await asyncio.sleep(1)
```

## 코드 스타일

- 타입 힌트 권장 (함수 시그니처)
- docstring은 복잡한 로직에만
- 상수는 UPPER_CASE
- 환경변수 로드는 진입점에서 한 번만
