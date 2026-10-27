"""For a tree, report whether each ground-truth defect is still present (pattern-based)."""
import re, sys, os
R = sys.argv[1]
def f(p): return open(os.path.join(R, p), encoding='utf-8').read()
def has(p, rx): return re.search(rx, f(p), re.M) is not None
def declares(p, cls, props):
    s = f(p); body = s[s.index('class ' + cls):]
    return all(re.search(r'(public|private|protected|var)\s+(readonly\s+)?(\??[\w\\]+\s+)?\$' + x + r'\b', body) or
               re.search(r'function __construct\([^)]*(public|private|protected)[^)]*\$' + x + r'\b', body) for x in props)
renamed = not os.path.exists(os.path.join(R, 'tests/unit/JiraClient_Test.php'))
tj = 'tests/unit/JiraClientTest.php' if renamed else 'tests/unit/JiraClient_Test.php'
tc = 'tests/unit/CurlClientTest.php' if renamed else 'tests/unit/CurlClient_Test.php'
checks = {
 'G01': has('features/slack/lib.php', r'->ok\s*(!=|==)\s*true'),
 'G02': not (has(tc, r'function setUp\(\)\s*:\s*void') and has(tj, r'function setUp\(\)\s*:\s*void')),
 'G03': not renamed,
 'G04': has('features/jira/lib.php', r'implode\(\$'),
 'G05': not has(tj, r'public static function provideTicketsFieldsRequirements'),
 'G06': has(tj, r'@dataProvider'),
 'G07': has(tj, r'returnValue\('),
 'G08': has(tj, r"createMock\('CurlClient',"),
 'G09': not (declares(tj, 'JiraClientTest', ['curl_client', 'jira_client']) and declares(tc, 'CurlClientTest', ['curl_client'])),
 'G10': not declares('features/jira/lib.php', 'JiraClient', ['curl_client', 'jira_base_url', 'username', 'password', 'proxy', 'additional_fields']),
 'G11': not (declares('features/calendar/lib.php', 'Calendar', ['clientId', 'apiKey', 'scopes', 'id', 'facilitator', 'attendees']) and declares('features/upload/lib/webdav.php', 'Uploader_Webdav', ['client'])),
 'G12': has('phplib/CurlClient.php', r'[^?]array \$params = null'),
 'G13': has('phplib/Persistence.php', r'get_array\(\$columns, \$where = (array\(\)|\[\]), \$table_name,'),
 'G14': has('phplib/Persistence.php', r'E_USER_ERROR'),
 'G15': has('features/anniversary/views/anniversary-mail.php', r'\$\{subject\}'),
 'G16': has('htdocs/index.php', r'MCRYPT_'),
 'G17': not has('phplib/Persistence.php', r'\$postmortem === false'),
 'G18': not has('features/history/routes.php', r'status\(404\)'),
 'G19': has('htdocs/index.php', r"trim\(\$app->request\(\)->get\('tags'\)\)") or has('phplib/Postmortem.php', r'new DateTime\(null') or has('features/search/routes.php', r'urldecode\(\$q\)') or has('features/anniversary/routes.php', r"trim\(\$app->request->get\('date'\)\)"),
 'G20': has('features/links/routes.php', r'get_forum_link\(\$img\)'),
}
print(' '.join(f"{k}:{'OPEN' if v else 'fixed'}" for k, v in checks.items()))
