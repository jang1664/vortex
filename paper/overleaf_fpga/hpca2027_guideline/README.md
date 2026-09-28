# HPCA 2027 제출 가이드

공식 HPCA 2027 웹사이트에서 2026-08-01 (KST)에 확인한 내용을 정리했다. 규정은 갱신될 수 있으므로 실제 제출 직전에는 아래 **공식 Main Track 페이지**를 다시 확인한다. 웹페이지와 동봉된 샘플 PDF/LaTeX 템플릿이 다를 경우, 더 최근에 갱신된 공식 웹페이지와 PC chair 안내를 우선한다.

- 공식 Main Track 규정: <https://conf.researchr.org/track/hpca-2027/hpca-2027-main-conference>
- 공식 Industry Track 규정: <https://conf.researchr.org/track/hpca-2027/hpca-2027-industry-track>

## 핵심 일정

| 항목 | 공식 마감 (AoE, UTC-12) | 한국 시간 (KST, UTC+9) |
|---|---:|---:|
| 논문 등록 및 초록 제출 | 2026-07-24 23:59 | 2026-07-25 20:59 |
| 본문 제출 | 2026-07-31 23:59 | 2026-08-01 20:59 |
| Revision/Rebuttal | 2026-09-28 ~ 2026-10-09 | 공식 시각 미공지 |
| 결과 발표 | 2026-11-06 | 공식 시각 미공지 |
| Camera-ready | TBA | TBA |

- 개최: 2027-03-20 ~ 2027-03-24, Salt Lake City, Utah, USA
- Main Track 제출: <https://hpca2027.hotcrp.com/>
- 문의: <hpca27chairs@gmail.com>

## 형식 체크리스트

- [ ] 인쇄 가능한 PDF
- [ ] 본문 최대 11쪽, 참고문헌은 페이지 제한에서 제외
- [ ] US Letter (8.5 × 11 inch)
- [ ] 2단, single-spaced, 단 사이 간격 0.1 inch
- [ ] 여백: 위 0.7, 아래 1.0, 좌우 0.7 inch
- [ ] 본문 10pt Times 이상, leading 12pt 이상
- [ ] 초록 9pt Times bold
- [ ] 섹션 제목 12pt small caps 및 Roman numbering
- [ ] 서브섹션 제목 10pt italic 및 alphabetic numbering
- [ ] 캡션 9pt 이상
- [ ] 참고문헌 8pt, 페이지 제한 없음, 모든 저자 이름 명시 (`et al.` 금지)
- [ ] 페이지 번호 포함
- [ ] 첫 페이지 상단에 submission number와 confidentiality 배너 포함 (`NaN`을 실제 번호로 교체)

## 익명성 및 내용

- Double-blind review이므로 제출 PDF에서 저자 이름과 신원을 드러내는 정보를 제거한다.
- PDF metadata에도 저자 정보가 없어야 한다.
- 자기 논문을 포함한 기존 연구는 3인칭으로 서술하고 정상적으로 완전 인용한다. Blind review를 이유로 참고문헌을 누락하거나 익명화하지 않는다.
- 그림과 표는 인쇄 및 grayscale에서도 구별 가능하고 읽을 수 있어야 하며, 본문에서 반드시 언급한다.

## 등록 단계 주의사항

- 등록 시 title, abstract, author list, conflict list를 실제 최종 제출본에 가깝게 확정한다.
- 등록 후 author list는 변경할 수 없고 순서만 바꿀 수 있다. 부득이한 변경은 본문 마감 최소 48시간 전에 PC chairs에게 이메일로 요청한다.
- 등록 초록과 최종 논문 사이의 합리적 문구 수정은 가능하지만, 논문 정체성이 달라질 정도의 변경은 desk rejection 사유가 될 수 있다.
- 모든 conflict를 등록한다. 누락하거나 심사 배정을 조작하려고 허위 conflict를 선언하면 desk rejection될 수 있다.

## Reserve reviewer (Light PC)

각 논문은 최대 6편을 리뷰할 수 있는 senior author 한 명을 지정해야 한다. 리뷰를 배정받으면 시의적절하고 품질 높은 리뷰를 제출해야 자기 논문의 리뷰 공개가 지연되지 않는다.

다음은 공식 페이지에 명시된 예외다.

- senior author가 없는 논문
- senior author 중 한 명 이상이 이미 main/light PC인 경우
- 모든 senior author가 다음 중 하나 이상에 해당하는 경우
  - TCCA, TCMM, SIGARCH, SIGMICRO 후원 학회에 출판한 적이 없음
  - 작년·올해·내년에 150편 이상 제출을 받은 해당 단체 학회의 (co-)chair
  - 집필은 가능했지만 리뷰가 불가능한 특별 사정이 있으며, 등록 마감 최소 3일 전에 PC chairs의 승인을 받음

## Conflict of Interest 요약

공식 규정상 다음 관계는 conflict로 선언한다.

1. 박사·박사후과정 지도교수와 피지도자: 영구
2. 가족: 영구 (잠재적 reviewer일 수 있는 경우)
3. 최근 4년 이내 공동 연구·개발, 공동 논문, reviewer 개인으로부터의 직접 연구비 관계
4. 현재 같은 기관, 최근 4년 이내 같은 기관, 또는 상대 기관에서 채용 심사 중인 관계
5. 잠재 reviewer가 관련된 연구비 관계
6. 미공개 연구를 정기적으로 논의하는 같은 연구센터 구성원
7. 객관적 평가를 방해하는 기타 관계

유사 주제 연구자라는 이유만으로는 conflict가 아니다. PC뿐 아니라 잠재적인 모든 reviewer와의 conflict를 제출 시스템에 선언한다.

## arXiv, IEEE CAL, 중복 제출

- arXiv 또는 IEEE CAL에 올라간 연구도 제출할 수 있으나 double-blind 노출 위험을 줄여야 한다. 공식 페이지는 HPCA 제출본의 제목·초록을 지나치게 비슷하게 하지 않도록 권고하고, 이미 arXiv에 올렸다면 HPCA 제출본 제목을 바꾸라고 안내한다.
- 실질적으로 유사한 논문이 이미 출판·채택되었거나 HPCA 심사 기간 중 다른 학회·저널·archived workshop proceedings에서 동시 심사 중이면 안 된다.
- 예외는 archived proceedings가 없는 workshop, 또는 긴 conference paper 제출을 허용하는 IEEE CAL/arXiv 등이며, 이 사실은 제출 폼에 공개한다.

## AI 사용 정책

- AI가 생성한 텍스트·그림·이미지·코드 등을 사용했다면 참고문헌 뒤에 `AI use` appendix를 추가한다. 이 appendix는 11쪽 제한에 포함되지 않는다.
- 사용한 AI 시스템, AI가 쓰인 구체적인 논문 부분, 사용 수준을 간단히 설명한다.
- 문법 교정·편집만을 위한 AI 사용은 공개가 권장되지만 의무는 아니다.

## Industry Track 추가 요건

- 실제 산업 제품 또는 프로세스에 직접 관련된 고유한 통찰이 있어야 한다. 배포 제품, roadmap 제품, 취소된 제품에서 얻은 교훈 등이 대상이다.
- 제1저자와 저자의 과반수가 industry 소속이어야 한다. Internship이나 visiting student 역할은 이 요건의 industry author로 계산하지 않는다.
- HotCRP에 모든 소속(dual academic affiliation 포함)을 정확히 공개한다. 누락 시 desk rejection이다.
- PDF에서는 저자 신원을 익명화하지만, 산업 연관성과 신뢰성 평가에 필요한 회사명과 제품명은 익명화하지 않아도 된다.
- 단기 인턴 프로젝트나 구체적인 산업 제품/프로세스와 연결되지 않은 speculative work는 Industry Track 대상이 아니다.
- Industry Track 제출: <https://hpca2027industry.hotcrp.com/>

## 포함 파일

- `hpca2027_template.pdf`: 공식 3쪽 formatting sample/guideline
- `hpca2027-latex-template.tar.gz`: 공식 LaTeX 템플릿 원본 압축 파일
- `hpca2027-latex-template/`: 위 압축 파일을 푼 작업용 템플릿
- `SOURCES.md`: 공식 출처 URL, 확인일, 다운로드 파일 checksum

> 주의: 동봉된 PDF/LaTeX 샘플은 기본 형식 확인에 유용하지만, 공식 웹페이지에는 reserve reviewer와 최신 등록·AI 정책 등 더 자세하고 갱신된 내용이 있다.
