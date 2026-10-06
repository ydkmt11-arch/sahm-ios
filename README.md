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

## Notifications (v1.3)
The owner's SAHM notifications arrive as iPhone notifications with the app's own name and icon. A free Apple ID cannot
sign remote push (APNs needs a paid developer account), so `Sahm/Notifier.swift` polls the server's
`GET /api/notify/feed?since=<id>` — every minute while the app is open, and whenever iOS wakes it in the background
(Background App Refresh, `UIBackgroundModes: fetch`, task `io.github.ydkmt11arch.sahm.refresh`; iOS decides when,
usually 15 minutes or more apart, never after a force-quit). Off until the owner taps «تفعيل» in the admin panel's
notifications section (`SahmApp.notifyEnable(true)` → the iOS permission prompt), so nothing prompts by itself.
CI: the real scenario checks the bridge and a native read of the feed (`?ci=1`, not counted as the owner's phone).
