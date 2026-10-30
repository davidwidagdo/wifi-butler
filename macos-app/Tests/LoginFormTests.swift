import Foundation

func testLoginForm() {
    let base = URL(string: "http://portal.example/hotspot-detect.html")

    // MikroTik redirect.html as served to a logged-out client.
    let meta = """
    <html><head><title>...</title>
    <meta http-equiv="refresh" content="0; url=http://portal.example/login?dst=http%3A%2F%2Fcaptive.apple.com%2F">
    <meta http-equiv="pragma" content="no-cache"></head><body></body></html>
    """
    T.eq(LoginFormParser.redirectURL(html: meta, base: base)?.absoluteString,
         "http://portal.example/login?dst=http%3A%2F%2Fcaptive.apple.com%2F", "meta refresh target")

    let js = "<script>location.href = unescape('http%3A%2F%2Fportal.example%2Fstatus');</script>"
    T.eq(LoginFormParser.redirectURL(html: js, base: base)?.absoluteString,
         "http://portal.example/status", "js unescape target")

    let replace = "<script>window.location.replace(\"/login\");</script>"
    T.eq(LoginFormParser.redirectURL(html: replace, base: base)?.absoluteString,
         "http://portal.example/login", "js location.replace target")

    let relative = "<meta http-equiv='refresh' content='0;URL=/login'>"
    T.eq(LoginFormParser.redirectURL(html: relative, base: base)?.absoluteString,
         "http://portal.example/login", "relative meta target")

    let lookalike = "<script>var geolocation = 'http://tracker.example/';</script>"
    T.expect(LoginFormParser.redirectURL(html: lookalike, base: base) == nil, "lookalike variable ignored")

    let template = "<meta http-equiv=\"refresh\" content=\"0; url=$(link-redirect)\">"
    T.expect(LoginFormParser.redirectURL(html: template, base: base) == nil, "unexpanded template ignored")

    let success = "<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>"
    T.expect(LoginFormParser.redirectURL(html: success, base: base) == nil, "no redirect on success page")

    // MikroTik login.html: a hidden "sendin" form precedes the real one.
    let login = """
    <meta http-equiv="refresh" content="30; url=/login">
    <form name="sendin" action="http://portal.example/login" method="post">
      <input type="hidden" name="username" /><input type="hidden" name="password" />
    </form>
    <form name="login" action="http://portal.example/login" method="post" onSubmit="return doLogin()">
      <input type="hidden" name="dst" value="" /><input type="hidden" name="popup" value="true" />
      <input name="username" type="text" /><input name="password" type="password" />
    </form>
    """
    T.expect(LoginFormParser.redirectURL(html: login, base: base) == nil, "form page is not followed")
    let form = LoginFormParser.parse(html: login)
    T.eq(form?.fields.map(\.name) ?? [], ["dst", "popup", "username", "password"], "real login form picked")
    let filled = Dictionary(uniqueKeysWithValues: form?.filled(username: "u", password: "p#1") ?? [])
    T.eq(filled["username"] ?? "", "u", "username filled")
    T.eq(filled["password"] ?? "", "p#1", "password filled")
    T.eq(filled["popup"] ?? "", "true", "hidden field kept")
}
