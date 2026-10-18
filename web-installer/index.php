<?php
/*
 * Faveo Web Installer
 *
 * One-page PHP tool that installs Faveo Helpdesk on a client server over SSH.
 * The client server downloads faveo-helpdesk-docker from GitHub and runs
 * faveo-run.sh with the options entered here. The installation runs in the
 * background on this server; its output is streamed back into the page.
 *
 * Requirements on this (web) server: PHP 7.4+ with proc_open/exec enabled,
 * the php CLI, ssh, and sshpass (only for password logins).
 *
 * SECURITY: this page logs in to servers with root/sudo rights. Set
 * ACCESS_PASSWORD, serve it over HTTPS only, and keep DATA_DIR outside the
 * web root (or rely on the generated .htaccess on Apache).
 */

// ----------------------------------------------------------------------------
// Configuration
// ----------------------------------------------------------------------------
const ACCESS_PASSWORD = '123';                       // required to open the page ('' = no login)
const DATA_DIR        = __DIR__ . '/data';         // job logs, known_hosts (keep private)
const PHP_CLI         = '/usr/bin/php';            // PHP command-line binary
const SSHPASS_BIN     = '/usr/bin/sshpass';
const SSH_BIN         = '/usr/bin/ssh';
const REPO_TARBALL    = 'https://codeload.github.com/vvitsivakumar/FaveoOnDocker/tar.gz/refs/heads/main';
const REPO_FOLDER     = 'FaveoOnDocker-main/faveo-helpdesk-docker';
const STANDALONE_FOLDER = 'FaveoOnDocker-main/stand-alone-installl';   // standalone (no containers) installer
const REMOTE_DIR      = '$HOME/faveo-docker-installer';   // where the client server keeps the installer

// ----------------------------------------------------------------------------
// Background worker (CLI):  php index.php worker <job-id>
// ----------------------------------------------------------------------------
if (PHP_SAPI === 'cli') {
    if (($argv[1] ?? '') === 'worker' && preg_match('/^[a-f0-9]{32}$/', $argv[2] ?? '')) {
        run_worker($argv[2]);
    }
    exit;
}

function job_path(string $id, string $ext): string
{
    return DATA_DIR . "/$id.$ext";
}

function write_status(string $id, array $status): void
{
    file_put_contents(job_path($id, 'status'), json_encode($status), LOCK_EX);
}

function run_worker(string $id): void
{
    set_time_limit(0);
    umask(0077);

    $jobFile = job_path($id, 'job');
    $job = json_decode((string) @file_get_contents($jobFile), true);
    @unlink($jobFile);                                   // secrets are not kept on disk
    $log = job_path($id, 'log');
    if (!is_array($job)) {
        file_put_contents($log, "ERROR: job data not found.\n", FILE_APPEND);
        write_status($id, ['done' => true, 'exit' => 1]);
        return;
    }

    $keyFile = null;
    $env = ['PATH' => '/usr/local/bin:/usr/bin:/bin', 'HOME' => DATA_DIR];
    $ssh = [SSH_BIN,
        '-p', (string) $job['ssh_port'],
        '-o', 'StrictHostKeyChecking=accept-new',
        '-o', 'UserKnownHostsFile=' . DATA_DIR . '/known_hosts',
        '-o', 'ConnectTimeout=20',
        '-o', 'ServerAliveInterval=30',
        '-o', 'ServerAliveCountMax=10',
    ];
    if ($job['auth'] === 'password') {
        $env['SSHPASS'] = $job['ssh_password'];
        $ssh = array_merge([SSHPASS_BIN, '-e'], $ssh, [
            '-o', 'PubkeyAuthentication=no',
            '-o', 'PreferredAuthentications=password,keyboard-interactive',
            '-o', 'NumberOfPasswordPrompts=1',
        ]);
    } else {
        $keyFile = job_path($id, 'key');
        file_put_contents($keyFile, rtrim(str_replace("\r", '', $job['ssh_key'])) . "\n");
        chmod($keyFile, 0600);
        $ssh = array_merge($ssh, ['-i', $keyFile, '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes']);
    }
    $ssh[] = $job['ssh_user'] . '@' . $job['host'];
    // The installer script is NOT passed on the command line: one argument may be at most 128 KB
    // on Linux, and certificates (e.g. a large CA bundle) can exceed that. Instead the script is
    // sent over stdin as one base64 line, saved to a private temp file on the client server and
    // run from there (it deletes itself when it starts). The next stdin line is the sudo password.
    $ssh[] = 'umask 077; f=$(mktemp) || exit 1; '
           . 'if IFS= read -r s && printf \'%s\' "$s" | base64 -d > "$f"; then unset s; bash "$f"; rc=$?; '
           . 'else echo "ERROR: could not receive the installer script."; rc=1; fi; rm -f "$f"; exit $rc';

    file_put_contents($log, sprintf("==> %s  Connecting to %s@%s:%d (%s login)\n",
        date('Y-m-d H:i:s'), $job['ssh_user'], $job['host'], $job['ssh_port'], $job['auth']), FILE_APPEND);

    $proc = proc_open($ssh, [0 => ['pipe', 'r'], 1 => ['file', $log, 'a'], 2 => ['file', $log, 'a']], $pipes, null, $env);
    if (!is_resource($proc)) {
        file_put_contents($log, "ERROR: could not start ssh.\n", FILE_APPEND);
        write_status($id, ['done' => true, 'exit' => 1]);
        $keyFile && @unlink($keyFile);
        return;
    }
    fwrite($pipes[0], base64_encode($job['remote_script']) . "\n");   // the installer script (see above)
    fwrite($pipes[0], $job['sudo_password'] . "\n");       // read by the remote script (sudo -S)
    fclose($pipes[0]);
    $exit = proc_close($proc);
    $keyFile && @unlink($keyFile);

    $msg = [0 => 'Installation finished successfully.',
            5 => 'SSH login failed (wrong password?).',
            255 => 'SSH connection failed (host, port, user or key wrong, or server unreachable).'];
    file_put_contents($log, sprintf("\n==> %s  %s (exit code %d)\n", date('Y-m-d H:i:s'),
        $msg[$exit] ?? 'Installation FAILED - see the output above.', $exit), FILE_APPEND);
    write_status($id, ['done' => true, 'exit' => $exit]);
}

// ----------------------------------------------------------------------------
// Web request
// ----------------------------------------------------------------------------
session_start();
header('X-Frame-Options: DENY');
header('X-Content-Type-Options: nosniff');

if (!is_dir(DATA_DIR)) {
    @mkdir(DATA_DIR, 0700, true);
}
if (is_dir(DATA_DIR) && !file_exists(DATA_DIR . '/.htaccess')) {
    @file_put_contents(DATA_DIR . '/.htaccess', "Require all denied\n");
}
if (empty($_SESSION['csrf'])) {
    $_SESSION['csrf'] = bin2hex(random_bytes(16));
}

function json_out(array $data, int $code = 200): void
{
    http_response_code($code);
    header('Content-Type: application/json');
    echo json_encode($data);
    exit;
}

function h(string $s): string
{
    return htmlspecialchars($s, ENT_QUOTES, 'UTF-8');
}

$action = $_GET['action'] ?? '';

// --- Login --------------------------------------------------------------------
if (ACCESS_PASSWORD !== '' && empty($_SESSION['authed'])) {
    $loginError = '';
    if ($_SERVER['REQUEST_METHOD'] === 'POST' && isset($_POST['access_password'])) {
        if (hash_equals(ACCESS_PASSWORD, (string) $_POST['access_password'])) {
            session_regenerate_id(true);
            $_SESSION['authed'] = true;
            header('Location: ' . strtok($_SERVER['REQUEST_URI'], '?'));
            exit;
        }
        $loginError = 'Wrong password.';
        sleep(1);
    }
    if ($action !== '') {
        json_out(['error' => 'Not logged in.'], 401);
    }
    render_login($loginError);
    exit;
}

// --- Log polling ----------------------------------------------------------------
if ($action === 'log') {
    $id = (string) ($_GET['job'] ?? '');
    if (!preg_match('/^[a-f0-9]{32}$/', $id) || !in_array($id, $_SESSION['jobs'] ?? [], true)) {
        json_out(['error' => 'Unknown job.'], 404);
    }
    $offset = max(0, (int) ($_GET['offset'] ?? 0));
    $data = '';
    if (is_file($f = job_path($id, 'log'))) {
        $fh = fopen($f, 'r');
        fseek($fh, $offset);
        $data = (string) stream_get_contents($fh, 512 * 1024);
        fclose($fh);
    }
    $data = preg_replace('/\e\[[0-9;?]*[A-Za-z]/', '', $data);   // strip ANSI colours
    $status = json_decode((string) @file_get_contents(job_path($id, 'status')), true) ?: ['done' => false];
    json_out(['data' => $data, 'offset' => $offset + strlen($data)] + $status);
}

// --- Start installation ---------------------------------------------------------
if ($action === 'start' && $_SERVER['REQUEST_METHOD'] === 'POST') {
    if (!hash_equals($_SESSION['csrf'], (string) ($_POST['csrf'] ?? ''))) {
        json_out(['error' => 'Session expired - reload the page.'], 403);
    }
    [$job, $errors] = build_job($_POST, $_FILES);
    if ($errors) {
        json_out(['errors' => $errors], 422);
    }
    foreach (['proc_open', 'exec'] as $fn) {
        if (!function_exists($fn)) {
            json_out(['errors' => ["PHP function $fn() is disabled on this web server."]], 500);
        }
    }
    if (!is_writable(DATA_DIR)) {
        json_out(['errors' => ['Folder ' . DATA_DIR . ' is not writable by the web server.']], 500);
    }
    if ($job['auth'] === 'password' && !is_executable(SSHPASS_BIN)) {
        json_out(['errors' => ['sshpass is not installed on this web server (needed for password login). Install it or use a private key.']], 500);
    }

    $id = bin2hex(random_bytes(16));
    $old = umask(0077);
    file_put_contents(job_path($id, 'job'), json_encode($job), LOCK_EX);
    file_put_contents(job_path($id, 'log'), '');
    write_status($id, ['done' => false]);
    umask($old);

    exec(sprintf('nohup %s %s worker %s > /dev/null 2>&1 &',
        escapeshellarg(PHP_CLI), escapeshellarg(__FILE__), $id));

    $_SESSION['jobs'][] = $id;
    json_out(['job' => $id]);
}

render_page();
exit;

// ----------------------------------------------------------------------------
// Validation + remote command
// ----------------------------------------------------------------------------
function build_job(array $in, array $files): array
{
    $e = [];
    $v = fn(string $k, string $d = '') => trim((string) ($in[$k] ?? $d));
    $port = function (string $k, string $label, bool $required = false) use ($v, &$e) {
        $p = $v($k);
        if ($p === '') {
            if ($required) $e[] = "$label is required.";
            return null;
        }
        if (!ctype_digit($p) || (int) $p < 1 || (int) $p > 65535) {
            $e[] = "$label must be a number between 1 and 65535.";
            return null;
        }
        return (int) $p;
    };
    $isHost = fn(string $s) => filter_var($s, FILTER_VALIDATE_IP) !== false
        || (bool) preg_match('/^(?=.{1,253}$)[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$/', $s);

    $type = $v('install_type');
    if (!in_array($type, ['docker', 'standalone'], true)) {
        return [null, ['Choose Docker or Standalone - Kubernetes is not available yet.']];
    }

    // Client server / SSH
    $host = $v('host');
    if (!$isHost($host)) $e[] = 'Client host name / IP address is not valid.';
    $sshPort = $port('ssh_port', 'SSH port', true);
    $sshUser = $v('ssh_user', 'root');
    if (!preg_match('/^[A-Za-z_][A-Za-z0-9_.-]{0,31}$/', $sshUser)) $e[] = 'SSH user name is not valid.';
    $auth = $v('auth') === 'key' ? 'key' : 'password';
    $sshPassword = (string) ($in['ssh_password'] ?? '');
    $sshKey = (string) ($in['ssh_key'] ?? '');
    if ($auth === 'key' && !empty($files['ssh_key_file']['tmp_name']) && is_uploaded_file($files['ssh_key_file']['tmp_name'])) {
        $sshKey = (string) file_get_contents($files['ssh_key_file']['tmp_name']);
    }
    if ($auth === 'password' && $sshPassword === '') $e[] = 'SSH password is required.';
    if ($auth === 'key') {
        if (!preg_match('/-----BEGIN [A-Z ]*PRIVATE KEY-----/', $sshKey)) {
            $e[] = 'Paste or upload a private key (-----BEGIN ... PRIVATE KEY-----).';
        } elseif (strpos($sshKey, 'ENCRYPTED') !== false) {
            $e[] = 'Password-protected private keys are not supported - use a key without a passphrase.';
        }
    }
    $sudoPassword = (string) ($in['sudo_password'] ?? '');
    if ($sudoPassword === '' && $auth === 'password') $sudoPassword = $sshPassword;
    if (strpbrk($sudoPassword, "\r\n") !== false) $e[] = 'Sudo password cannot contain line breaks.';

    // Faveo (faveo-run.sh options)
    $domain = strtolower(preg_replace('#^https?://#i', '', rtrim($v('domain'), '/')));
    if (!preg_match('/^[a-z0-9][a-z0-9.-]*$/', $domain)) $e[] = 'Domain may contain only letters, digits, "-" and ".".';
    $email = $v('email');
    if (!filter_var($email, FILTER_VALIDATE_EMAIL)) $e[] = 'Email address is not valid.';
    $license = $v('license');
    if (!preg_match('/^[A-Za-z0-9-]+$/', $license)) $e[] = 'License code may contain only letters, digits and "-".';
    $order = ltrim($v('order'), '#');
    if (!preg_match('/^[A-Za-z0-9-]+$/', $order)) $e[] = 'Order number may contain only letters, digits and "-".';
    $ssl = $v('ssl');
    if (!in_array($ssl, ['certbot', 'self-signed', 'paid-ssl'], true)) $e[] = 'Choose an SSL type.';
    $yes = fn(string $k) => $v($k) === 'yes';
    // Certificate / key from one of three sources: an uploaded file, pasted PEM text, or the path
    // of a file that is already on the client server (passed as-is; the installer reads and checks
    // it there). Returns '' when nothing usable was given.
    $pem = function (string $k, string $src) use ($in, $files): string {
        if ($src === 'path') {
            $p = trim((string) ($in[$k . '_path'] ?? ''));
            return (preg_match('#^/[A-Za-z0-9._/@+-]{1,250}$#', $p) && strpos($p, '..') === false) ? $p : '';
        }
        $text = '';
        if ($src === 'paste') {
            $text = (string) ($in[$k] ?? '');
        } elseif (!empty($files[$k . '_file']['tmp_name']) && is_uploaded_file($files[$k . '_file']['tmp_name'])) {
            $text = (string) file_get_contents($files[$k . '_file']['tmp_name']);
        }
        $text = str_replace("\r", '', trim($text));
        return strpos($text, '-----BEGIN') === false ? '' : base64_encode($text . "\n");
    };
    $src = function (string $k) use ($v): string {
        $s = $v($k, 'upload');
        return in_array($s, ['upload', 'paste', 'path'], true) ? $s : 'upload';
    };
    $srcHelp = ['upload' => 'upload the PEM file', 'paste' => 'paste the PEM content', 'path' => 'give the full path of the file on the client server, starting with /'];
    $dbPassRe = '/^[A-Za-z0-9@#%^*_+=.,:!?-]{8,64}$/';
    $dbPassRule = '8-64 characters: letters, digits and @ # % ^ * _ + = . , : ! ? -';

    // Paid SSL certificate (same options for both installers)
    $sslArgs = [];
    if ($ssl === 'paid-ssl') {
        $sslSrc = $src('ssl_src');
        foreach (['certfile' => 'Certificate (.crt)', 'keyfile' => 'Private key (.key)', 'cacertfile' => 'CA bundle (.crt)'] as $k => $label) {
            if (($val = $pem($k, $sslSrc)) === '') { $e[] = "Paid SSL - $label: " . $srcHelp[$sslSrc] . '.'; continue; }
            array_push($sslArgs, "--$k", $val);
        }
    }

    $ssh = ['host' => $host, 'ssh_port' => $sshPort, 'ssh_user' => $sshUser, 'auth' => $auth,
            'ssh_password' => $sshPassword, 'ssh_key' => $sshKey, 'sudo_password' => $sudoPassword];

    // ------------------------------------------------------------------ Standalone (stand-alone-installl/faveo.sh)
    if ($type === 'standalone') {
        if (strlen($license) !== 16) $e[] = 'Standalone: the license code must be exactly 16 characters.';
        if (strlen($order) !== 8) $e[] = 'Standalone: the order number must be exactly 8 characters.';
        $pick = function (string $k, array $allowed, string $default, string $label) use ($v, &$e): string {
            $val = $v($k, $default);
            if (!in_array($val, $allowed, true)) { $e[] = "$label must be " . implode(', ', $allowed) . '.'; return $default; }
            return $val;
        };
        $sa = ['--domain', $domain, '--email', $email, '--license', $license, '--order', $order, '--ssl', $ssl];
        $sa = array_merge($sa, $sslArgs);
        array_push($sa,
            '--release',   $pick('sa_release', ['official', 'rc', 'beta'], 'official', 'Release'),
            '--faveoenv',  $pick('sa_env', ['production', 'development', 'testing'], 'production', 'Environment'),
            '--webserver', $pick('sa_webserver', ['apache', 'nginx'], 'apache', 'Web server'),
            '--sql',       $pick('sa_sql', ['mysql', 'mariadb'], 'mysql', 'Database engine'),
            '--meili',     $pick('sa_meili', ['yes', 'no'], 'yes', 'Meilisearch'),
            '--node',      $pick('sa_node', ['yes', 'no'], 'yes', 'Node.js'),
            '--nats',      $pick('sa_nats', ['yes', 'no'], 'no', 'NATS'));
        $php = $v('sa_php') ?: '8.4';
        if (!preg_match('/^([8-9]|[1-9][0-9])\.[0-9]+$/', $php)) $e[] = 'PHP version must be 8.x or newer, e.g. 8.4.';
        array_push($sa, '--php', $php);

        if ($v('sa_db') === 'remote') {
            $dbHost = $v('sa_db_host');
            if (!$isHost($dbHost)) $e[] = 'Remote database: server address is not valid.';
            $dbPort = $port('sa_db_port', 'Remote database port') ?? 3306;
            $dbUser = $v('sa_db_user');
            if ($dbUser === '' || strpos($dbUser, '--') === 0) $e[] = 'Remote database: admin user is required.';
            $dbPw = (string) ($in['sa_db_password'] ?? '');
            if ($dbPw === '' || strpos($dbPw, '--') === 0) $e[] = 'Remote database: admin password is required (and cannot start with --).';
            array_push($sa, '--sqlreser', 'yes', '--sqlhost', $dbHost, '--sqlport', (string) $dbPort,
                '--sqlusername', $dbUser, '--sqlpassword', $dbPw);
            if ($yes('sa_db_ssl')) {
                $dbSrc = $src('sadbssl_src');
                array_push($sa, '--sqlsecure', 'yes');
                if (($ca = $pem('sa_db_ssl_ca', $dbSrc)) === '') $e[] = 'Remote database SSL - CA certificate: ' . $srcHelp[$dbSrc] . '.';
                else array_push($sa, '--sqlsslca', $ca);
                $cert = $pem('sa_db_ssl_cert', $dbSrc);
                $key = $pem('sa_db_ssl_key', $dbSrc);
                if (($cert === '') !== ($key === '')) $e[] = 'Remote database SSL: give both the client certificate and the client key, or neither.';
                if ($cert !== '' && $key !== '') array_push($sa, '--sqlsslcert', $cert, '--sqlsslkey', $key);
                array_push($sa, '--sslverify', $v('sa_db_ssl_verify') === 'no' ? 'no' : 'yes');
            } else {
                array_push($sa, '--sqlsecure', 'no');
            }
        } else {
            array_push($sa, '--sqlreser', 'no');
        }

        if ($e) return [null, $e];
        return [$ssh + ['remote_script' => remote_script(STANDALONE_FOLDER, 'faveo.sh', 'bash faveo.sh', $sa)], []];
    }

    // ------------------------------------------------------------------ Docker (faveo-helpdesk-docker/faveo-run.sh)
    $args = ['-d', $domain, '-e', $email, '-l', $license, '-o', $order, '-s', $ssl, '-y', '--no-banner'];
    $args = array_merge($args, $sslArgs);

    // Release and features
    $release = $v('release', 'official');
    if (!in_array($release, ['official', 'rc', 'beta'], true)) $e[] = 'Release must be official, rc or beta.';
    $faveoEnv = $v('faveo_env', 'production');
    if (!in_array($faveoEnv, ['production', 'development', 'testing'], true)) $e[] = 'Environment must be production, development or testing.';
    array_push($args, '-r', $release, '-w', $yes('websocket') ? 'yes' : 'no', '--faveo-env', $faveoEnv);
    if ($v('auto_setup', 'yes') === 'no') $args[] = '--skip-faveo-setup';

    // Installation folder
    if ($yes('custom_dir')) {
        $dir = rtrim($v('install_dir'), '/');
        if (!preg_match('#^/[A-Za-z0-9._/-]+$#', $dir)) $e[] = 'Installation folder must be an absolute path (letters, digits, . _ - /).';
        array_push($args, '-i', $dir);
        if ($yes('force')) $args[] = '--force';
    }

    // Database
    $remoteDb = $v('db') === 'remote';
    if ($remoteDb) {
        $dbHost = $v('db_host');
        if (!$isHost($dbHost)) $e[] = 'Remote database: server address is not valid.';
        array_push($args, '--db', 'remote', '--db-host', $dbHost);
        if (($p = $port('db_port', 'Remote database port')) !== null) array_push($args, '--db-port', (string) $p);
        $dbAdmin = $v('db_admin_user') ?: 'root';
        if (!preg_match('/^[A-Za-z0-9_.@-]{1,64}$/', $dbAdmin)) $e[] = 'Remote database: admin user is not valid.';
        $dbAdminPw = (string) ($in['db_admin_password'] ?? '');
        if ($dbAdminPw === '') $e[] = 'Remote database: admin password is required.';
        array_push($args, '--db-admin-user', $dbAdmin, '--db-admin-password', $dbAdminPw);
        if ($yes('db_ssl')) {
            array_push($args, '--db-ssl', 'yes');
            $dbSrc = $src('dbssl_src');
            if (($ca = $pem('db_ssl_ca', $dbSrc)) === '') $e[] = 'Remote database SSL - CA certificate: ' . $srcHelp[$dbSrc] . '.';
            else array_push($args, '--db-ssl-ca', $ca);
            $cert = $pem('db_ssl_cert', $dbSrc);
            $key = $pem('db_ssl_key', $dbSrc);
            if (($cert === '') !== ($key === '')) $e[] = 'Remote database SSL: give both the client certificate and the client key, or neither.';
            if ($cert !== '' && $key !== '') array_push($args, '--db-ssl-cert', $cert, '--db-ssl-key', $key);
            array_push($args, '--db-ssl-verify', $v('db_ssl_verify') === 'no' ? 'no' : 'yes');
        }
    } else {
        $args = array_merge($args, ['--db', 'local']);
    }
    if ($yes('custom_db')) {
        foreach (['db_name' => ['--db-name', 'Database name'], 'db_user' => ['--db-user', 'Database user']] as $k => [$flag, $label]) {
            if (($val = $v($k)) === '') continue;
            if (!preg_match('/^[A-Za-z0-9_]{1,32}$/', $val)) $e[] = "$label may contain only letters, digits and _ (max 32).";
            array_push($args, $flag, $val);
        }
        $pwFields = ['db_password' => ['--db-password', 'Database user password']];
        if (!$remoteDb) $pwFields['db_root_password'] = ['--db-root-password', 'MySQL root password'];
        foreach ($pwFields as $k => [$flag, $label]) {
            $val = (string) ($in[$k] ?? '');
            if ($val === '') continue;
            if (!preg_match($dbPassRe, $val)) $e[] = "$label: $dbPassRule.";
            array_push($args, $flag, $val);
        }
    }

    // Ports
    if ($yes('custom_ports')) {
        if ($ssl === 'certbot') $e[] = "Custom ports cannot be used with Let's Encrypt (it always needs ports 80 and 443). Choose self-signed or paid SSL.";
        $used = [];
        foreach (['http_port' => ['--http-port', 'HTTP port'], 'https_port' => ['--https-port', 'HTTPS port']] as $k => [$flag, $label]) {
            if (($p = $port($k, $label)) !== null) { array_push($args, $flag, (string) $p); $used[$label] = $p; }
        }
        if ($yes('supervisor_disable')) {
            array_push($args, '--supervisor-port', 'none');
        } elseif (($p = $port('supervisor_port', 'Supervisor port')) !== null) {
            array_push($args, '--supervisor-port', (string) $p); $used['Supervisor port'] = $p;
        }
        if (count($used) !== count(array_unique($used))) $e[] = 'HTTP, HTTPS and Supervisor ports must all be different.';
        if ($v('auto_ports', 'yes') === 'yes') $args[] = '--auto-ports';
    } else {
        // Default ports: if one is already in use on the client server, use the next free one
        // (Let's Encrypt still needs 80 and 443 and stops if they are busy).
        $args[] = '--auto-ports';
    }

    // Docker network
    if ($yes('custom_subnet')) {
        $subnet = $v('subnet');
        if (!preg_match('#^(\d{1,3})\.(\d{1,3})\.0\.0/16$#', $subnet, $m) || $m[1] > 255 || $m[2] > 255) $e[] = 'Subnet must look like 172.24.0.0/16.';
        array_push($args, '--subnet', $subnet);
    }

    // Image versions and timezone
    if ($yes('custom_versions')) {
        if (($php = $v('php_version')) !== '') {
            if (!preg_match('/^8\.\d$/', $php)) $e[] = 'PHP version must look like 8.4.';
            array_push($args, '--php', $php);
        }
        if (($node = $v('node_version')) !== '') {
            if (!preg_match('/^\d{2}$/', $node)) $e[] = 'Node.js version must be a major version such as 22.';
            array_push($args, '--node', $node);
        }
        if (($tz = $v('timezone')) !== '') {
            if (!preg_match('#^[A-Za-z_]+(/[A-Za-z0-9_+-]+){0,2}$#', $tz)) $e[] = 'Timezone must look like Area/City, e.g. Asia/Kolkata.';
            array_push($args, '--timezone', $tz);
        }
    }

    // Behaviour
    if ($v('install_docker', 'yes') === 'yes') $args[] = '--install-docker';
    if ($v('on_failure') === 'keep') $args[] = '--keep-on-failure';
    if ($v('mode') === 'generate') $args[] = '--generate-only';

    if ($e) return [null, $e];

    return [$ssh + ['remote_script' => remote_script(REPO_FOLDER, 'faveo-run.sh', './faveo-run.sh', $args)], []];
}

/**
 * Script run on the client server over SSH: checks root / sudo, downloads the
 * repository tarball, unpacks the installer folder and runs the installer with
 * the given (shell-escaped) arguments. The sudo password, if any, arrives on stdin.
 */
function remote_script(string $folder, string $label, string $runner, array $args): string
{
    // Certificates / keys given as content (base64) are written to files on the client server and
    // passed as paths: one command-line argument may be at most 128 KB, and a CA bundle can be larger.
    $certFlags = ['--certfile', '--keyfile', '--cacertfile', '--db-ssl-ca', '--db-ssl-cert', '--db-ssl-key',
                  '--sqlsslca', '--sqlsslcert', '--sqlsslkey'];
    $files = '';
    $words = [];
    $n = 0;
    foreach ($args as $i => $a) {
        $prev = $i > 0 ? $args[$i - 1] : '';
        if (in_array($prev, $certFlags, true) && $a !== '' && $a[0] !== '/') {
            $n++;
            $files .= "base64 -d > \"\$CERTS/$n.pem\" <<'FAVEO_PEM_$n' || { echo \"ERROR: could not write certificate file $n.\"; exit 1; }\n"
                    . chunk_split($a, 76, "\n") . "FAVEO_PEM_$n\n";
            $words[] = "\"\$CERTS/$n.pem\"";
        } else {
            $words[] = escapeshellarg($a);
        }
    }

    return sprintf(<<<'SH'
rm -f "$0" 2>/dev/null          # this temp file holds passwords: remove it right away (bash keeps reading it)
set -o pipefail
URL=%1$s
FOLDER=%2$s
IFS= read -r SUDO_PW || true
echo "==> Connected to $(hostname) as $(id -un)"
if [ "$(id -u)" -eq 0 ]; then
    SUDO_MODE=root
elif ! command -v sudo >/dev/null 2>&1; then
    echo "ERROR: user $(id -un) is not root and sudo is not installed."; exit 1
elif sudo -n true 2>/dev/null; then
    SUDO_MODE=nopasswd
elif [ -n "$SUDO_PW" ] && printf '%%s\n' "$SUDO_PW" | sudo -S -p '' true 2>/dev/null; then
    SUDO_MODE=password
else
    echo "ERROR: sudo needs a password for $(id -un) - enter the correct sudo password."; exit 1
fi
DIR="%3$s"
mkdir -p "$DIR" && cd "$DIR" || { echo "ERROR: cannot create $DIR"; exit 1; }
echo "==> Downloading the Faveo installer from GitHub into $DIR"
if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$URL" -o faveo.tar.gz
elif command -v wget >/dev/null 2>&1; then
    wget -qO faveo.tar.gz "$URL"
else
    echo "ERROR: curl or wget is needed on the client server."; exit 1
fi || { echo "ERROR: download failed."; exit 1; }
rm -rf "$FOLDER"
tar -xzf faveo.tar.gz "$FOLDER" || { echo "ERROR: could not unpack the download."; exit 1; }
rm -f faveo.tar.gz
cd "$FOLDER" && chmod +x ./*.sh
CERTS=$(mktemp -d) || { echo "ERROR: cannot create a temporary folder."; exit 1; }
trap 'rm -rf "$CERTS"' EXIT
trap 'rm -rf "$CERTS"; exit 130' HUP INT TERM
%7$s
echo "==> Running %4$s in $PWD"
echo
case "$SUDO_MODE" in
    root)     %5$s %6$s </dev/null ;;
    nopasswd) sudo -n %5$s %6$s </dev/null ;;
    password) printf '%%s\n' "$SUDO_PW" | sudo -S -p '' %5$s %6$s ;;
esac
SH,
        escapeshellarg(REPO_TARBALL), escapeshellarg($folder), REMOTE_DIR, $label, $runner,
        implode(' ', $words), $files);
}

// ----------------------------------------------------------------------------
// HTML
// ----------------------------------------------------------------------------
function page_head(string $title): void
{ ?>
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title><?= h($title) ?></title>
<style>
:root {
  color-scheme:light;
  --bg:#f7f8fc; --card:#ffffff; --text:#1d2433; --muted:#667085; --line:#e3e7ef;
  --accent:#4f46e5; --accent-2:#7c3aed; --accent-soft:#eef2ff; --accent-text:#ffffff;
  --req:#e11d48; --ok:#059669; --err:#dc2626; --warn:#d97706;
  --input:#f8f9fd; --code-bg:#0f1222; --code-text:#d7dcf5; --shadow:0 1px 2px rgba(16,24,40,.06), 0 4px 16px rgba(16,24,40,.05);
}
* { box-sizing:border-box; }
body { margin:0; background:var(--bg); color:var(--text); font:15px/1.55 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; }
.wrap { max-width:900px; margin:0 auto; padding:0 16px 56px; }

/* Header */
.hero { margin:0 -16px 22px; padding:26px 24px 22px; color:#fff;
        background:linear-gradient(120deg, #4338ca 0%, #6d28d9 55%, #9333ea 100%); border-radius:0 0 14px 14px; }
.hero h1 { font-size:1.6rem; margin:0 0 4px; letter-spacing:.2px; }
.hero p { margin:0; opacity:.9; }
.legend { display:inline-flex; align-items:center; gap:6px; margin:0 0 18px; padding:6px 12px; border-radius:999px;
          background:var(--accent-soft); color:var(--text); font-size:.85rem; }
.legend b { color:var(--req); }

/* Cards and sections */
.card { background:var(--card); border:1px solid var(--line); border-radius:14px; padding:22px; margin-bottom:18px; box-shadow:var(--shadow); }
.card h2 { display:flex; align-items:center; gap:10px; font-size:1.08rem; margin:0 0 16px; }
.num { display:inline-grid; place-items:center; width:28px; height:28px; border-radius:50%; font-size:.85rem; font-weight:700;
       color:var(--accent-text); background:linear-gradient(135deg, var(--accent), var(--accent-2)); flex:none; }
.grid { display:grid; grid-template-columns:repeat(auto-fit, minmax(240px, 1fr)); gap:16px; }

/* Fields */
label { display:block; font-weight:600; font-size:.9rem; margin-bottom:5px; }
label .opt { font-weight:400; color:var(--muted); }
label.req::after { content:" *"; color:var(--req); font-weight:700; }
input[type=text], input[type=password], input[type=email], input[type=number], select, textarea {
  width:100%; padding:10px 12px; border:1px solid var(--line); border-radius:9px; background:var(--input); color:var(--text);
  font:inherit; transition:border-color .15s, box-shadow .15s; }
input::placeholder, textarea::placeholder { color:var(--muted); opacity:.75; }
textarea { font-family:ui-monospace, Menlo, Consolas, monospace; font-size:.8rem; min-height:90px; }
input:focus, select:focus, textarea:focus { outline:none; border-color:var(--accent); box-shadow:0 0 0 3px color-mix(in srgb, var(--accent) 25%, transparent); }
input[type=file] { font-size:.82rem; color:var(--muted); }
.hint { color:var(--muted); font-size:.82rem; margin:5px 0 0; }

/* Yes / No and other choices as pills */
.radio { display:flex; gap:8px; flex-wrap:wrap; }
.radio label { display:flex; gap:7px; align-items:center; font-weight:500; margin:0; padding:7px 14px; border:1px solid var(--line);
               border-radius:999px; background:var(--input); cursor:pointer; }
.radio label:has(input:checked) { border-color:var(--accent); background:var(--accent-soft); color:var(--text); }
.radio input { accent-color:var(--accent); margin:0; }
.checks label { display:flex; gap:8px; align-items:center; font-weight:400; margin:6px 0; }
.q { padding:14px 0; border-top:1px dashed var(--line); }
.q > label { margin-bottom:8px; }
.sub-q { margin:0 0 12px 12px; padding:6px 0 6px 16px; border-left:3px solid var(--accent); }
.sub-q .q { border-top:0; padding:10px 0 4px; }
details summary { cursor:pointer; font-weight:600; }
details[open] summary { margin-bottom:14px; }

/* Buttons, notices, output */
.btn { background:linear-gradient(135deg, var(--accent), var(--accent-2)); color:#fff; border:0; border-radius:10px; padding:12px 26px;
       font:inherit; font-weight:700; cursor:pointer; box-shadow:0 6px 18px color-mix(in srgb, var(--accent) 30%, transparent); }
.btn:hover { filter:brightness(1.07); }
.btn:disabled { opacity:.55; cursor:not-allowed; box-shadow:none; }
.notice { padding:12px 14px; border-radius:9px; border:1px solid var(--line); background:var(--input); }
.errors { color:var(--err); border-color:color-mix(in srgb, var(--err) 45%, transparent); background:color-mix(in srgb, var(--err) 8%, var(--card)); }
.errors ul { margin:0; padding-left:18px; }
.hidden { display:none !important; }
.status { font-weight:700; padding:2px 10px; border-radius:999px; }
.status.ok  { color:var(--ok);   background:color-mix(in srgb, var(--ok) 12%, transparent); }
.status.err { color:var(--err);  background:color-mix(in srgb, var(--err) 12%, transparent); }
.status.run { color:var(--warn); background:color-mix(in srgb, var(--warn) 12%, transparent); }
pre#log { background:var(--code-bg); color:var(--code-text); padding:14px; border-radius:10px; height:460px; overflow:auto;
          white-space:pre-wrap; word-break:break-word; font:12.5px/1.45 ui-monospace, Menlo, Consolas, monospace; margin:12px 0 0; }
.login { max-width:400px; margin:40px auto 0; }
</style>
</head>
<body>
<div class="wrap">
<?php }

function render_login(string $error): void
{
    page_head('Faveo Installer'); ?>
  <div class="hero"><h1>Faveo Installer</h1><p>Sign in to continue.</p></div>
  <form method="post" class="card login">
    <?php if ($error): ?><p class="notice errors"><?= h($error) ?></p><?php endif; ?>
    <label for="ap" class="req">Access password</label>
    <input type="password" id="ap" name="access_password" autofocus required>
    <p><button class="btn" type="submit">Log in</button></p>
  </form>
</div></body></html>
<?php }

function render_page(): void
{
    // Yes / No question
    $yn = function (string $name, string $question, string $default, string $hint = ''): void { ?>
        <div class="q">
          <label><?= h($question) ?> <span class="opt">[<?= $default ?>]</span></label>
          <div class="radio">
            <label><input type="radio" name="<?= $name ?>" value="yes"<?= $default === 'yes' ? ' checked' : '' ?>> Yes</label>
            <label><input type="radio" name="<?= $name ?>" value="no"<?= $default === 'no' ? ' checked' : '' ?>> No</label>
          </div>
          <?php if ($hint !== ''): ?><p class="hint"><?= h($hint) ?></p><?php endif; ?>
        </div>
    <?php };
    // Certificate / key: upload or paste
    $pem = function (string $name, string $label, string $group, string $example, bool $required = false): void { ?>
        <div><label<?= $required ? ' class="req"' : '' ?>><?= h($label) ?></label>
          <div data-when="<?= $group ?>_src=upload"><input type="file" name="<?= $name ?>_file"></div>
          <div data-when="<?= $group ?>_src=paste"><textarea name="<?= $name ?>" placeholder="-----BEGIN ...----- ... -----END ...-----"></textarea></div>
          <div data-when="<?= $group ?>_src=path"><input type="text" name="<?= $name ?>_path" placeholder="e.g. <?= h($example) ?>"></div>
        </div>
    <?php };
    // How the certificate files are provided
    $srcChoice = function (string $group): void { ?>
        <label>How do you want to provide the files?</label>
        <div class="radio" style="margin-bottom:12px">
          <label><input type="radio" name="<?= $group ?>_src" value="upload" checked> Upload the files</label>
          <label><input type="radio" name="<?= $group ?>_src" value="paste"> Paste the content</label>
          <label><input type="radio" name="<?= $group ?>_src" value="path"> Path on the client server</label>
        </div>
        <p class="hint" data-when="<?= $group ?>_src=path" style="margin:-4px 0 12px">The files must already be on the client server; give their full paths. They are read and checked there during the installation.</p>
    <?php };

    page_head('Faveo Installer'); ?>
  <div class="hero">
    <h1>Faveo Installer</h1>
    <p>Install Faveo Helpdesk on a client server. The server downloads the installer from GitHub and runs it over SSH.</p>
  </div>
  <p class="legend">Fields marked <b>*</b> are required. Values in [brackets] are the defaults.</p>
  <?php if (ACCESS_PASSWORD === ''): ?>
  <p class="notice errors">ACCESS_PASSWORD is not set in index.php - anyone who can open this page can run installations. Set it before using this page outside a private network.</p>
  <?php endif; ?>

  <form id="f" autocomplete="off" enctype="multipart/form-data">
    <input type="hidden" name="csrf" value="<?= h($_SESSION['csrf']) ?>">

    <div class="card">
      <h2><span class="num">1</span> Installation type</h2>
      <label class="req" for="install_type">Install Faveo with</label>
      <select id="install_type" name="install_type">
        <option value="">- Select -</option>
        <option value="docker">Docker</option>
        <option value="kubernetes">Kubernetes</option>
        <option value="standalone">Standalone (no containers)</option>
      </select>
      <p id="soon" class="notice hidden" style="margin-top:12px">This installation type is not available yet. Choose Docker or Standalone.</p>
      <p class="hint" data-when="install_type=docker">Faveo runs in Docker containers. Works on most Linux distributions.</p>
      <p class="hint" data-when="install_type=standalone">Faveo is installed directly on the server (Apache or Nginx, PHP, MySQL or MariaDB) - no containers.</p>
    </div>

    <div id="common" class="hidden">
      <div class="card">
        <h2><span class="num">2</span> Client server (SSH access)</h2>
        <div class="grid">
          <div><label class="req" for="host">Host name or IP address</label>
            <input type="text" id="host" name="host" placeholder="e.g. 203.0.113.10 or server.siva.com" required></div>
          <div><label class="req" for="ssh_port">SSH port</label>
            <input type="number" id="ssh_port" name="ssh_port" value="22" min="1" max="65535" required></div>
          <div><label class="req" for="ssh_user">SSH user</label>
            <input type="text" id="ssh_user" name="ssh_user" value="siva" required>
            <p class="hint">root, or a user with sudo rights.</p></div>
        </div>
        <div style="margin-top:14px">
          <label class="req">Log in with</label>
          <div class="radio">
            <label><input type="radio" name="auth" value="password" checked> Password</label>
            <label><input type="radio" name="auth" value="key"> Private key</label>
          </div>
        </div>
        <div class="grid" style="margin-top:12px">
          <div id="auth_password"><label class="req" for="ssh_password">SSH password</label>
            <input type="password" id="ssh_password" name="ssh_password" placeholder="Password of the SSH user"></div>
          <div id="auth_key" class="hidden" style="grid-column:1/-1">
            <label class="req" for="ssh_key">Private key</label>
            <textarea id="ssh_key" name="ssh_key" placeholder="-----BEGIN OPENSSH PRIVATE KEY-----&#10;...&#10;-----END OPENSSH PRIVATE KEY-----"></textarea>
            <p class="hint">Paste the key or upload the file (no passphrase): <input type="file" name="ssh_key_file"></p>
          </div>
          <div><label for="sudo_password">Sudo password <span class="opt">(if not root)</span></label>
            <input type="password" id="sudo_password" name="sudo_password" placeholder="Only if the SSH user is not root">
            <p class="hint">Leave empty to use the SSH password, or if sudo needs no password.</p></div>
        </div>
      </div>

      <div class="card">
        <h2><span class="num">3</span> Faveo details</h2>
        <div class="grid">
          <div><label class="req" for="domain">Domain</label>
            <input type="text" id="domain" name="domain" placeholder="e.g. siva.com or helpdesk.siva.com" required>
            <p class="hint">Without https://. Its DNS A record must point to the client server.</p></div>
          <div><label class="req" for="email">Admin email</label>
            <input type="email" id="email" name="email" placeholder="e.g. admin@siva.com" required>
            <p class="hint">Also used for Let's Encrypt.</p></div>
          <div><label class="req" for="license">License code</label>
            <input type="text" id="license" name="license" placeholder="e.g. ABCD1234EFGH5678 (16 characters)" required>
            <p class="hint">From billing.faveohelpdesk.com</p></div>
          <div><label class="req" for="order">Order number</label>
            <input type="text" id="order" name="order" placeholder="e.g. 12345678" required>
            <p class="hint">'#' is removed. Standalone: exactly 8 characters.</p></div>
          <div><label class="req" for="ssl">SSL certificate</label>
            <select id="ssl" name="ssl">
              <option value="certbot">Let's Encrypt (free, needs ports 80 / 443)</option>
              <option value="self-signed">Self-signed (browser warning)</option>
              <option value="paid-ssl">Paid SSL (your certificate files)</option>
            </select></div>
        </div>
        <div data-when="ssl=paid-ssl" style="margin-top:16px">
          <?php $srcChoice('ssl'); ?>
          <div class="grid">
            <?php $pem('certfile', 'Certificate (certificate.crt)', 'ssl', '/root/ssl/certificate.crt', true);
                  $pem('keyfile', 'Private key (private.key)', 'ssl', '/root/ssl/private.key', true);
                  $pem('cacertfile', 'CA bundle (ca_bundle.crt)', 'ssl', '/root/ssl/ca_bundle.crt', true); ?>
          </div>
          <p class="hint">The private key must match the certificate.</p>
        </div>
      </div>

      <div id="docker-opts" class="hidden">
      <div class="card">
        <h2><span class="num">4</span> Installation options</h2>
        <p class="hint" style="margin-top:-8px">Answer "No" to keep the default shown in brackets.</p>

        <div class="q">
          <div class="grid">
            <div><label for="release">Which Faveo release? <span class="opt">[official]</span></label>
              <select id="release" name="release">
                <option value="official">Official</option>
                <option value="rc">Release candidate (RC)</option>
                <option value="beta">Beta</option>
              </select></div>
            <div><label for="faveo_env">Application environment <span class="opt">[production]</span></label>
              <select id="faveo_env" name="faveo_env">
                <option value="production">Production</option>
                <option value="development">Development</option>
                <option value="testing">Testing</option>
              </select></div>
          </div>
        </div>

        <?php $yn('websocket', 'Do you need WebSocket (live updates and chat)?', 'no'); ?>

        <div class="q">
          <label>Where should the database run? <span class="opt">[local]</span></label>
          <div class="radio">
            <label><input type="radio" name="db" value="local" checked> Local MySQL 8.4 container</label>
            <label><input type="radio" name="db" value="remote"> Remote MySQL / MariaDB server</label>
          </div>
        </div>
        <div class="sub-q" data-when="db=remote">
          <p class="hint">The database and user are created on that server; it must be new or empty.</p>
          <div class="grid">
            <div><label class="req" for="db_host">Server address</label>
              <input type="text" id="db_host" name="db_host" placeholder="e.g. db.siva.com or 10.0.0.20"></div>
            <div><label for="db_port">Port <span class="opt">[3306]</span></label>
              <input type="number" id="db_port" name="db_port" placeholder="e.g. 3306 (default)" min="1" max="65535"></div>
            <div><label for="db_admin_user">Admin user <span class="opt">[root]</span></label>
              <input type="text" id="db_admin_user" name="db_admin_user" placeholder="e.g. root (default)"></div>
            <div><label class="req" for="db_admin_password">Admin password</label>
              <input type="password" id="db_admin_password" name="db_admin_password" placeholder="Password of the admin user"></div>
          </div>
          <?php $yn('db_ssl', 'Use an encrypted (SSL) connection to the database?', 'no'); ?>
          <div class="sub-q" data-when="db_ssl=yes">
            <?php $srcChoice('dbssl'); ?>
            <div class="grid">
              <?php $pem('db_ssl_ca', 'CA certificate', 'dbssl', '/root/db-ssl/ca.pem', true);
                    $pem('db_ssl_cert', 'Client certificate (optional)', 'dbssl', '/root/db-ssl/client-cert.pem');
                    $pem('db_ssl_key', 'Client key (with the client certificate)', 'dbssl', '/root/db-ssl/client-key.pem'); ?>
            </div>
            <?php $yn('db_ssl_verify', "Check the database server's identity?", 'yes'); ?>
          </div>
        </div>

        <?php $yn('custom_ports', 'Do you need custom ports?', 'no', 'Default: HTTP 80, HTTPS 443, Supervisor 9001 (this server only). If a port is already in use on the client server, the next free port is used automatically - except with Let\'s Encrypt, which always needs 80 and 443.'); ?>
        <div class="sub-q" data-when="custom_ports=yes">
          <p class="notice errors" data-when="ssl=certbot">Let's Encrypt always needs ports 80 and 443. Choose Self-signed or Paid SSL in section 3 to use other ports.</p>
          <div class="grid">
            <div><label for="http_port">Apache HTTP port <span class="opt">[80]</span></label>
              <input type="number" id="http_port" name="http_port" placeholder="e.g. 8091 (default 80)" min="1" max="65535"></div>
            <div><label for="https_port">Apache HTTPS port <span class="opt">[443]</span></label>
              <input type="number" id="https_port" name="https_port" placeholder="e.g. 8443 (default 443)" min="1" max="65535"></div>
          </div>
          <?php $yn('supervisor_disable', 'Turn off the Supervisor web port?', 'no'); ?>
          <div class="grid" data-when="supervisor_disable=no">
            <div><label for="supervisor_port">Supervisor port <span class="opt">[9001]</span></label>
              <input type="number" id="supervisor_port" name="supervisor_port" placeholder="e.g. 9002 (default 9001)" min="1" max="65535"></div>
          </div>
          <?php $yn('auto_ports', 'If one of these ports is already in use, take the next free one?', 'yes', 'Choose "No" to stop the installation instead.'); ?>
        </div>

        <?php $yn('custom_subnet', 'Do you need a custom Docker network subnet?', 'no', 'Default: 172.24.0.0/16. If it is already in use on the client server (another Docker network, LAN or VPN), the next free subnet is chosen automatically.'); ?>
        <div class="sub-q" data-when="custom_subnet=yes">
          <div class="grid">
            <div><label for="subnet">Subnet</label>
              <input type="text" id="subnet" name="subnet" placeholder="e.g. 172.30.0.0/16">
              <p class="hint">Must be free on the client server - a subnet that is already in use stops the installation.</p></div>
          </div>
        </div>

        <div class="q">
          <label>If the installation fails <span class="opt">[roll back]</span></label>
          <div class="radio">
            <label><input type="radio" name="on_failure" value="rollback" checked> Roll back everything this run created</label>
            <label><input type="radio" name="on_failure" value="keep"> Keep the files to investigate</label>
          </div>
        </div>
      </div>

      </div>

      <div id="sa-opts" class="hidden">
      <div class="card">
        <h2><span class="num">4</span> Installation options - Standalone</h2>
        <p class="hint" style="margin-top:-8px">Faveo is installed directly on the server, without containers. Supported: Ubuntu 22.04 / 24.04 / 26.04, Debian 11 / 12, RHEL, Rocky Linux and AlmaLinux 8 / 9 / 10.</p>

        <div class="q">
          <div class="grid">
            <div><label for="sa_release">Which Faveo release? <span class="opt">[official]</span></label>
              <select id="sa_release" name="sa_release">
                <option value="official">Official</option>
                <option value="rc">Release candidate (RC)</option>
                <option value="beta">Beta</option>
              </select></div>
            <div><label for="sa_env">Application environment <span class="opt">[production]</span></label>
              <select id="sa_env" name="sa_env">
                <option value="production">Production</option>
                <option value="development">Development</option>
                <option value="testing">Testing</option>
              </select></div>
          </div>
        </div>

        <div class="q">
          <div class="grid">
            <div><label for="sa_webserver">Web server <span class="opt">[apache]</span></label>
              <select id="sa_webserver" name="sa_webserver">
                <option value="apache">Apache</option>
                <option value="nginx">Nginx</option>
              </select></div>
            <div><label for="sa_sql">Database engine <span class="opt">[mysql]</span></label>
              <select id="sa_sql" name="sa_sql">
                <option value="mysql">MySQL</option>
                <option value="mariadb">MariaDB</option>
              </select></div>
            <div><label for="sa_php">PHP version <span class="opt">[8.4]</span></label>
              <input type="text" id="sa_php" name="sa_php" placeholder="e.g. 8.4"></div>
          </div>
        </div>

        <?php $yn('sa_meili', 'Install Meilisearch (search engine)?', 'yes'); ?>
        <?php $yn('sa_node', 'Install Node.js?', 'yes'); ?>
        <?php $yn('sa_nats', 'Install NATS (needed for Network Discovery)?', 'no'); ?>

        <div class="q">
          <label>Where should the database run? <span class="opt">[local]</span></label>
          <div class="radio">
            <label><input type="radio" name="sa_db" value="local" checked> On this server (installed by the script)</label>
            <label><input type="radio" name="sa_db" value="remote"> Remote MySQL / MariaDB server</label>
          </div>
        </div>
        <div class="sub-q" data-when="sa_db=remote">
          <p class="hint">The Faveo database and user are created on that server with the admin account.</p>
          <div class="grid">
            <div><label class="req" for="sa_db_host">Server address</label>
              <input type="text" id="sa_db_host" name="sa_db_host" placeholder="e.g. db.siva.com or 10.0.0.20"></div>
            <div><label for="sa_db_port">Port <span class="opt">[3306]</span></label>
              <input type="number" id="sa_db_port" name="sa_db_port" placeholder="e.g. 3306 (default)" min="1" max="65535"></div>
            <div><label class="req" for="sa_db_user">Admin user</label>
              <input type="text" id="sa_db_user" name="sa_db_user" placeholder="e.g. root"></div>
            <div><label class="req" for="sa_db_password">Admin password</label>
              <input type="password" id="sa_db_password" name="sa_db_password" placeholder="Password of the admin user"></div>
          </div>
          <?php $yn('sa_db_ssl', 'Use an encrypted (SSL) connection to the database?', 'no'); ?>
          <div class="sub-q" data-when="sa_db_ssl=yes">
            <?php $srcChoice('sadbssl'); ?>
            <div class="grid">
              <?php $pem('sa_db_ssl_ca', 'CA certificate', 'sadbssl', '/root/db-ssl/ca.pem', true);
                    $pem('sa_db_ssl_cert', 'Client certificate (optional)', 'sadbssl', '/root/db-ssl/client-cert.pem');
                    $pem('sa_db_ssl_key', 'Client key (with the client certificate)', 'sadbssl', '/root/db-ssl/client-key.pem'); ?>
            </div>
            <?php $yn('sa_db_ssl_verify', "Check the database server's identity?", 'yes'); ?>
          </div>
        </div>
      </div>
      </div>

      <div id="errors" class="notice errors hidden" style="margin-bottom:16px"></div>
      <button class="btn" id="submit" type="submit">Install Faveo</button>
    </div>
  </form>

  <div id="out" class="card hidden" style="margin-top:16px">
    <h2>Installation output</h2>
    <div>Status &nbsp;<span id="status" class="status run">Starting...</span></div>
    <pre id="log"></pre>
  </div>
</div>

<script>
(function () {
  var $ = function (id) { return document.getElementById(id); };
  var form = $('f');

  function toggle() {
    var type = $('install_type').value;
    var ready = type === 'docker' || type === 'standalone';
    $('common').classList.toggle('hidden', !ready);
    $('docker-opts').classList.toggle('hidden', type !== 'docker');
    $('sa-opts').classList.toggle('hidden', type !== 'standalone');
    $('soon').classList.toggle('hidden', type === '' || ready);
    var key = form.querySelector('input[name=auth]:checked').value === 'key';
    $('auth_password').classList.toggle('hidden', key);
    $('auth_key').classList.toggle('hidden', !key);
    $('ssh_password').required = !key;
    // Show a block only when its question has the given answer: data-when="name=value"
    form.querySelectorAll('[data-when]').forEach(function (el) {
      var cond = el.getAttribute('data-when').split('=');
      var field = form.elements[cond[0]];
      el.classList.toggle('hidden', !field || field.value !== cond[1]);
    });
  }
  form.addEventListener('change', toggle);
  toggle();

  function showErrors(list) {
    var box = $('errors');
    box.innerHTML = '';
    var ul = document.createElement('ul');
    list.forEach(function (m) { var li = document.createElement('li'); li.textContent = m; ul.appendChild(li); });
    box.appendChild(ul);
    box.classList.remove('hidden');
  }

  form.addEventListener('submit', function (ev) {
    ev.preventDefault();
    $('errors').classList.add('hidden');
    $('submit').disabled = true;
    fetch('?action=start', { method: 'POST', body: new FormData(form), credentials: 'same-origin' })
      .then(function (r) { return r.json(); })
      .then(function (res) {
        if (!res.job) { showErrors(res.errors || [res.error || 'Could not start the installation.']); $('submit').disabled = false; return; }
        $('out').classList.remove('hidden');
        $('log').textContent = '';
        $('out').scrollIntoView({ behavior: 'smooth' });
        poll(res.job, 0);
      })
      .catch(function () { showErrors(['Request failed - check the web server.']); $('submit').disabled = false; });
  });

  function poll(job, offset) {
    fetch('?action=log&job=' + job + '&offset=' + offset, { credentials: 'same-origin' })
      .then(function (r) { return r.json(); })
      .then(function (res) {
        var log = $('log');
        if (res.data) {
          var atBottom = log.scrollTop + log.clientHeight >= log.scrollHeight - 30;
          log.textContent += res.data;
          if (atBottom) log.scrollTop = log.scrollHeight;
        }
        var st = $('status');
        if (res.done) {
          var ok = res.exit === 0;
          st.textContent = ok ? 'Finished successfully' : 'Failed (exit code ' + res.exit + ')';
          st.className = 'status ' + (ok ? 'ok' : 'err');
          $('submit').disabled = false;
          return;
        }
        st.textContent = 'Installing... (this takes 10-20 minutes)';
        st.className = 'status run';
        setTimeout(function () { poll(job, res.offset || offset); }, 2000);
      })
      .catch(function () { setTimeout(function () { poll(job, offset); }, 5000); });
  }
})();
</script>
</body>
</html>
<?php }
