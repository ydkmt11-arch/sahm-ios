# سهم — تطبيق الآيفون

غلاف أصلي (WKWebView) يعرض **نفس الميني آب** من منصة سهم التي تعمل على جهاز المالك.

- **معرّف الحزمة:** `io.github.ydkmt11arch.sahm` (فريد؛ `com.sahm.app` محجوز لفريق آخر عند Apple، وهذا سبب خطأ SideStore 3011).
- **موقّع مسبقًا (fakesign)** بمساحة رأس إضافية، فيستطيع ldid في SideStore إعادة توقيعه؛ يُختبر ذلك في كل بناء.
- **النسخة الخاصة بالمالك:** المنصة تضيف `pair.json` (رمز الربط) إلى الـIPA عند تنزيله من لوحة الإدارة، فيفتح التطبيق المنصة مباشرة بعد التثبيت.
- **عنوان المنصة يتغير مع كل تشغيل** للكمبيوتر، فيجده التطبيق بنفسه: آخر عنوان نجح (بعد إثبات HMAC)، ثم المؤشر المشفّر في
  `huggingface.co/spaces/fdgwse5/sahm-app`، ثم العنوان المضمّن في النسخة.
- **كل بناء** يشغّل التطبيق في محاكي الآيفون: النسخة العامة، والنسخة الخاصة، والرمز الخطأ، والرابط العميق، ومنصة المالك الحقيقية
  مع لوحة الإدارة (صورها مشفّرة).

## التثبيت
من سهم في تيليجرام: ضغط مطوّل على «الرئيسية» ← «تثبيت تطبيق الآيفون» ← «تثبيت في SideStore».

## Notifications (v1.4)
SAHM's notifications arrive as iPhone notifications with the app's own name and icon.

**The hard limit, said plainly.** This IPA is sideloaded with a FREE Apple ID, and free provisioning cannot carry the
`aps-environment` entitlement, so APNs (remote push) is impossible without the paid Apple Developer Program ($99/yr).
`Sahm/Notifier.swift` therefore polls the server itself — `GET /api/notify/feed?since=<id>&did=<install>` — every
minute while the app is open, and whenever iOS wakes it: a `BGAppRefreshTask` **and** a `BGProcessingTask`
(`UIBackgroundModes: fetch, processing`; ids `…sahm.refresh` / `…sahm.process`). iOS alone decides if and when either
runs (usually ≥15 min apart, never after the app was swiped away), so **background delivery is best effort**.
Delivery that always arrives while the app is closed: Telegram, or Web Push to the interface added to the iPhone's
Home Screen (iOS 16.4+, free).

**v1.4 changes.** The system permission sheet appears by itself on the FIRST launch, like any other app (the switch in
the page stays as a fallback and for turning them off). Every install generates its own device id, sends it with the
feed requests and hands it to the page through `SahmApp.deviceId`, so each phone is one subscriber with its own
preferences on the server (kinds, threshold, quiet hours, channels, price alerts). Each feed id is shown at most once.

CI: scenario `firstlaunch` boots a fresh install with no `-ciNoPrompt` and asserts the app asked by itself
(`notify.asked`, `notify.prompted`, a 32-character device id) with a screenshot of the sheet; the `real` scenario
checks the bridge, the device id and a native read of the feed (`?ci=1`, not counted as a real phone).
