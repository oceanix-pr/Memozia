# Security Policy

[English](#english) · [简体中文](#zh-cn) · [繁體中文](#zh-tw) · [日本語](#ja) · [한국어](#ko) · [Español](#es) · [Français](#fr)

<a name="english"></a>

## English

### Report a vulnerability privately

Sign in to GitHub and use [Memozia's private vulnerability reporting form][private-report] to contact the maintainers. Keep vulnerability details in the private report while a fix is being coordinated.

Please include:

- The affected Memozia version and build number, macOS version, and Mac model. Include the processing mode (local or cloud) if relevant.
- A description of the issue, its potential impact, and steps to reproduce it with fictional data.
- A minimal proof of concept or redacted diagnostics, if available.

### Protect sensitive data

Do not upload real meeting recordings, transcripts, screenshots, API keys, access tokens, encryption keys, Keychain exports, or unredacted crash reports. Use fictional examples and remove personal information, credentials, and private file paths from diagnostics.

### Security and quality tools

- [Security advisories][advisories] contains published vulnerability notices and remediation guidance.
- **Dependabot** reports known vulnerabilities in recognized dependencies. GitHub Actions dependency updates are proposed weekly.
- **Code scanning** uses CodeQL for Python and GitHub Actions, and mobsfscan for Swift source security patterns. Checks run on pushes to the default branch, pull requests, a weekly schedule, and manual runs.
- **Secret scanning and push protection** detect potential credential exposure in repository content and incoming pushes.

See the [security overview][security-overview] for current status and findings.

### Security fixes and other feedback

Security fixes target the latest code on the default branch. Backports to older releases are considered based on the vulnerability's impact. Available updates are listed in [Releases][releases].

Email ordinary bug reports and feature requests to [oceanix-pr@outlook.com][feedback-email]. For translation feedback, use the [issue forms][issues].

<a name="zh-cn"></a>

## 简体中文

### 私下报告安全漏洞

请登录 GitHub，通过 [Memozia 私密漏洞报告表单][private-report]联系维护者。在协调修复期间，请将漏洞细节保留在私密报告中。

请提供：

- 受影响的 Memozia 版本及构建号、macOS 版本和 Mac 机型；如与问题相关，请注明本地或云端处理模式。
- 问题描述、潜在影响，以及使用虚构数据的复现步骤。
- 如有，提供最小概念验证示例或已脱敏的诊断信息。

### 保护敏感数据

请勿上传真实会议录音、转写、截图、API Key、访问令牌、加密密钥、钥匙串导出或未脱敏的崩溃报告。请使用虚构示例，并从诊断信息中移除个人信息、凭据和私人文件路径。

### 安全与质量检查

- [安全公告][advisories]提供已公开的漏洞通知与修复建议。
- **Dependabot** 对已识别依赖中的已知漏洞发出告警，并每周提出 GitHub Actions 依赖更新建议。
- **代码扫描**通过 CodeQL 分析 Python 和 GitHub Actions，通过 mobsfscan 检查 Swift 源码中的安全模式；在默认分支推送、PR、每周定时及手动运行时执行。
- **密钥扫描与推送保护**识别仓库内容及推送中潜在的凭据泄露。

当前状态与检查结果见[安全总览][security-overview]。

### 安全修复与其他反馈

安全修复以当前默认分支的最新代码为目标；历史版本是否回补按漏洞影响决定。可用更新见 [Releases][releases]。

普通故障和功能建议可发送至 [oceanix-pr@outlook.com][feedback-email]。翻译反馈请使用 [Issue 表单][issues]。

<a name="zh-tw"></a>

## 繁體中文

### 私下回報安全漏洞

請登入 GitHub，透過 [Memozia 私密漏洞回報表單][private-report]聯絡維護者。在協調修復期間，請將漏洞細節保留在私密回報中。

請提供：

- 受影響的 Memozia 版本及組建編號、macOS 版本和 Mac 機型；如與問題相關，請註明本機或雲端處理模式。
- 問題描述、潛在影響，以及使用虛構資料的重現步驟。
- 如有，提供最小概念驗證範例或已去識別化的診斷資訊。

### 保護敏感資料

請勿上傳真實會議錄音、逐字稿、截圖、API 金鑰、存取權杖、加密金鑰、鑰匙圈匯出資料或未去識別化的當機報告。請使用虛構範例，並從診斷資訊中移除個人資料、憑證和私人檔案路徑。

### 安全與品質檢查

- [安全公告][advisories]提供已公開的漏洞通知與修復建議。
- **Dependabot** 針對已識別相依套件中的已知漏洞發出警示，並每週提出 GitHub Actions 相依項目更新建議。
- **程式碼掃描**透過 CodeQL 分析 Python 和 GitHub Actions，透過 mobsfscan 檢查 Swift 原始碼中的安全模式；在預設分支推送、PR、每週排程及手動執行時執行。
- **機密掃描與推送保護**識別儲存庫內容及推送中可能洩露的憑證。

目前狀態與檢查結果請見[安全總覽][security-overview]。

### 安全修復與其他意見

安全修復以目前預設分支的最新程式碼為目標；是否將修補套用至舊版本，依漏洞影響決定。可用更新請見 [Releases][releases]。

一般問題和功能建議可寄至 [oceanix-pr@outlook.com][feedback-email]。翻譯意見請使用 [Issue 表單][issues]。

<a name="ja"></a>

## 日本語

### 脆弱性を非公開で報告する

GitHub にサインインし、[Memozia の非公開脆弱性報告フォーム][private-report]からメンテナーに連絡してください。修正の調整中は、脆弱性の詳細を非公開の報告内で共有してください。

次の情報を記載してください。

- 影響を受ける Memozia のバージョンとビルド番号、macOS のバージョン、Mac の機種。関係がある場合は、処理モード（ローカルまたはクラウド）も記載してください。
- 問題の説明、想定される影響、架空のデータを使った再現手順。
- 用意できる場合は、最小限の概念実証コードや、機密情報を除去した診断情報。

### 機密データの保護

実際の会議録音、文字起こし、スクリーンショット、API キー、アクセストークン、暗号化キー、キーチェーンのエクスポート、機密情報を含むクラッシュレポートはアップロードしないでください。架空の例を使い、診断情報から個人情報、認証情報、個人用ファイルパスを除去してください。

### セキュリティと品質のチェック

- [セキュリティアドバイザリ][advisories]で、公開された脆弱性情報と対処方法を確認できます。
- **Dependabot** は、認識された依存関係の既知の脆弱性を通知し、GitHub Actions の依存関係の更新を毎週提案します。
- **コードスキャン**では、CodeQL で Python と GitHub Actions を分析し、mobsfscan で Swift ソースの潜在的な脆弱性パターンを検査します。デフォルトブランチへのプッシュ、PR、週次スケジュール、手動実行時に動作します。
- **シークレットスキャンとプッシュ保護**は、リポジトリの内容やプッシュに含まれる認証情報の漏えいを検出します。

現在の状態と検出結果は[セキュリティの概要][security-overview]で確認してください。

### セキュリティ修正とその他のフィードバック

セキュリティ修正は、デフォルトブランチの最新コードを対象とします。旧リリースへの修正適用は、脆弱性の影響に応じて判断します。利用可能な更新は [Releases][releases] を確認してください。

通常の不具合の報告や機能の要望は [oceanix-pr@outlook.com][feedback-email] にお送りください。翻訳へのフィードバックには [Issue フォーム][issues]を利用してください。

<a name="ko"></a>

## 한국어

### 보안 취약점 비공개 신고

GitHub에 로그인한 뒤 [Memozia 비공개 취약점 신고 양식][private-report]으로 유지관리자에게 연락해 주세요. 수정 방안을 조율하는 동안 취약점의 세부 내용은 비공개 신고 안에서 공유해 주세요.

다음 정보를 포함해 주세요.

- 영향을 받는 Memozia 버전과 빌드 번호, macOS 버전, Mac 모델. 문제와 관련이 있다면 처리 모드(로컬 또는 클라우드)도 적어 주세요.
- 문제 설명, 예상 영향, 가상 데이터를 사용한 재현 단계.
- 가능한 경우 최소한의 개념 증명 예제 또는 민감한 정보를 제거한 진단 자료.

### 민감한 데이터 보호

실제 회의 녹음, 전사, 스크린샷, API 키, 액세스 토큰, 암호화 키, 키체인 내보내기 파일, 민감한 정보가 포함된 충돌 보고서를 업로드하지 마세요. 가상 예제를 사용하고 진단 자료에서 개인정보, 인증 정보, 개인 파일 경로를 제거해 주세요.

### 보안 및 품질 검사

- [보안 권고][advisories]에서 공개된 취약점 안내와 해결 방법을 확인할 수 있습니다.
- **Dependabot**은 인식된 의존성의 알려진 취약점을 알리고, 매주 GitHub Actions 의존성 업데이트를 제안합니다.
- **코드 검사**는 CodeQL로 Python과 GitHub Actions를 분석하고, mobsfscan으로 Swift 소스의 잠재적 보안 취약 패턴을 검사합니다. 기본 브랜치에 푸시할 때, PR, 주간 일정 및 수동 실행 시 수행됩니다.
- **비밀 검사와 푸시 보호**는 저장소 내용과 푸시에 포함된 인증 정보의 잠재적 유출을 탐지합니다.

현재 상태와 검사 결과는 [보안 개요][security-overview]에서 확인해 주세요.

### 보안 수정 및 기타 의견

보안 수정은 기본 브랜치의 최신 코드를 대상으로 합니다. 이전 릴리스에 대한 수정 적용 여부는 취약점의 영향에 따라 결정합니다. 제공되는 업데이트는 [Releases][releases]에서 확인해 주세요.

일반 오류 신고와 기능 제안은 [oceanix-pr@outlook.com][feedback-email]으로 보내 주세요. 번역 의견은 [Issue 양식][issues]을 이용해 주세요.

<a name="es"></a>

## Español

### Informar de una vulnerabilidad de forma privada

Inicia sesión en GitHub y utiliza el [formulario privado de vulnerabilidades de Memozia][private-report] para contactar con los responsables del proyecto. Mantén los detalles de la vulnerabilidad en el informe privado mientras se coordina la corrección.

Incluye:

- La versión y el número de compilación de Memozia afectados, la versión de macOS y el modelo de Mac. Indica el modo de procesamiento (local o en la nube) si es relevante.
- Una descripción del problema, su posible impacto y los pasos para reproducirlo con datos ficticios.
- Si dispones de ello, una prueba de concepto mínima o información de diagnóstico sin datos sensibles.

### Proteger los datos sensibles

No subas grabaciones reales de reuniones, transcripciones, capturas de pantalla, claves de API, tokens de acceso, claves de cifrado, exportaciones del Llavero ni informes de fallos que contengan datos sensibles. Utiliza ejemplos ficticios y elimina de los diagnósticos la información personal, las credenciales y las rutas de archivos privadas.

### Herramientas de seguridad y calidad

- Los [avisos de seguridad][advisories] muestran vulnerabilidades publicadas y orientaciones para corregirlas.
- **Dependabot** avisa de vulnerabilidades conocidas en las dependencias reconocidas y propone cada semana actualizaciones de las dependencias de GitHub Actions.
- **El análisis de código** utiliza CodeQL para Python y GitHub Actions, y mobsfscan para buscar patrones de riesgo en el código Swift. Se ejecuta con los cambios enviados a la rama predeterminada, las solicitudes de incorporación, las ejecuciones semanales y las ejecuciones manuales.
- **El análisis de secretos y la protección de envíos** detectan posibles filtraciones de credenciales en el repositorio y en los cambios enviados.

Consulta el estado y los resultados en la [vista general de seguridad][security-overview].

### Correcciones de seguridad y otros comentarios

Las correcciones de seguridad se aplican al código más reciente de la rama predeterminada. Su adaptación a versiones anteriores se evalúa según el impacto de la vulnerabilidad. Consulta las actualizaciones disponibles en [Releases][releases].

Envía los informes de errores habituales y las propuestas de funciones a [oceanix-pr@outlook.com][feedback-email]. Para comentarios sobre traducciones, utiliza los [formularios de incidencias][issues].

<a name="fr"></a>

## Français

### Signaler une vulnérabilité en privé

Connectez-vous à GitHub et utilisez le [formulaire privé de signalement de vulnérabilités de Memozia][private-report] pour contacter les responsables du projet. Conservez les détails de la vulnérabilité dans le signalement privé pendant la coordination du correctif.

Veuillez inclure :

- La version et le numéro de build de Memozia concernés, la version de macOS et le modèle de Mac. Précisez le mode de traitement (local ou cloud) si cela est pertinent.
- Une description du problème, de son impact potentiel et des étapes de reproduction avec des données fictives.
- Si possible, une preuve de concept minimale ou des informations de diagnostic expurgées des données sensibles.

### Protéger les données sensibles

Ne téléversez pas d'enregistrements réels de réunions, de transcriptions, de captures d'écran, de clés API, de jetons d'accès, de clés de chiffrement, d'exportations du Trousseau ni de rapports de plantage contenant des données sensibles. Utilisez des exemples fictifs et retirez des diagnostics les informations personnelles, les identifiants d'accès et les chemins de fichiers privés.

### Outils de sécurité et de qualité

- Les [avis de sécurité][advisories] présentent les vulnérabilités publiées et les mesures correctives.
- **Dependabot** signale les vulnérabilités connues des dépendances reconnues et propose chaque semaine des mises à jour des dépendances GitHub Actions.
- **L'analyse du code** utilise CodeQL pour Python et GitHub Actions, et mobsfscan pour rechercher des motifs à risque dans le code Swift. Elle s'exécute lors des envois vers la branche par défaut, des pull requests, des exécutions hebdomadaires et des exécutions manuelles.
- **L'analyse des secrets et la protection des envois** détectent les fuites potentielles d'identifiants d'accès dans le dépôt et les modifications envoyées.

Consultez l'état et les résultats dans la [vue d'ensemble de la sécurité][security-overview].

### Correctifs de sécurité et autres retours

Les correctifs de sécurité ciblent le code le plus récent de la branche par défaut. Leur adaptation aux anciennes versions est évaluée selon l'impact de la vulnérabilité. Les mises à jour disponibles figurent dans [Releases][releases].

Envoyez les signalements de bugs courants et les suggestions de fonctionnalités à [oceanix-pr@outlook.com][feedback-email]. Pour les retours sur les traductions, utilisez les [formulaires de signalement][issues].

[private-report]: https://github.com/oceanix-pr/Memozia/security/advisories/new
[feedback-email]: mailto:oceanix-pr@outlook.com
[releases]: https://github.com/oceanix-pr/Memozia/releases
[issues]: https://github.com/oceanix-pr/Memozia/issues/new/choose
[advisories]: https://github.com/oceanix-pr/Memozia/security/advisories
[security-overview]: https://github.com/oceanix-pr/Memozia/security
