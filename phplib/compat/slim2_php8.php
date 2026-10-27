<?php
/**
 * PHP 8 shims for slim/slim 2.6.3, which is abandoned and has no PHP 8 release.
 *
 * Loaded through composer.json "autoload.files", so it runs when vendor/autoload.php
 * is included, before any Slim class is touched. Every shim is guarded, so it is a
 * no-op on a runtime that still provides the symbol.
 */

if (!function_exists('get_magic_quotes_gpc')) {
    /**
     * Removed in PHP 8.0 (magic quotes were gone since 5.4, so the answer is always
     * false). Slim\Http\Util::stripSlashesIfMagicQuotes() calls it on every request.
     */
    function get_magic_quotes_gpc()
    {
        return false;
    }
}

// ext/mcrypt left core in 7.2 and was never in the php docker image. Slim::getDefaultSettings()
// reads these constants on every `new \Slim\Slim()`; on PHP 8 an undefined constant is an
// Error. Values are ext/mcrypt's own. Slim\Http\Util::encrypt()/decrypt() check
// extension_loaded('mcrypt') and return data unchanged without it, as on the 7.1 baseline.
if (!defined('MCRYPT_RIJNDAEL_256')) {
    define('MCRYPT_RIJNDAEL_256', 'rijndael-256');
}
if (!defined('MCRYPT_MODE_CBC')) {
    define('MCRYPT_MODE_CBC', 'cbc');
}
