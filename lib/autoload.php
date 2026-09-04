<?php

/**
 * Мінімальний PSR-4 автозавантажувач для бібліотек флоу перекладу.
 *
 * Composer тут навмисно не використовується: ці скрипти запускаються і на хості,
 * і всередині контейнера, часто до будь-якого `composer install`, і не мають
 * залежати від стану vendor/. Простір імен один, правило одне.
 */
spl_autoload_register(static function (string $class): void {
    $prefix = 'Bdo\\Translate\\';
    if (! str_starts_with($class, $prefix)) {
        return;
    }
    $relative = substr($class, strlen($prefix));
    $path = __DIR__.'/'.str_replace('\\', '/', $relative).'.php';
    if (is_file($path)) {
        require_once $path;
    }
});

/**
 * Єдиний вигляд помилки для всіх скриптів флоу.
 *
 * Ці скрипти читає агент, а не людина в IDE: PHP-трасування він переказує
 * власнику як «сталася помилка», втрачаючи текст, у якому написано, що робити.
 * Тому назовні йде тільки повідомлення. Повне трасування вмикає BDO_DEBUG=1.
 */
set_exception_handler(static function (Throwable $e): void {
    $message = 'ПОМИЛКА: '.$e->getMessage()."\n";
    if (getenv('BDO_DEBUG') === '1') {
        $message .= $e->getTraceAsString()."\n";
    }
    // `STDERR` існує лише в CLI. Під вбудованим сервером (сторінка `./bdo web`)
    // ця константа не визначена, і сам обробник падав із «Undefined constant
    // STDERR» · тобто ХОВАВ справжню причину за собою: 2026-09-05 через це
    // `/api/state` віддавав HTML-помилку замість стану, а сторінка мовчки
    // показувала застарілий знімок (D70).
    if (defined('STDERR')) {
        fwrite(STDERR, $message);
    } else {
        error_log(rtrim($message));
        if (! headers_sent()) {
            http_response_code(500);
            header('Content-Type: application/json; charset=utf-8');
        }
        echo json_encode(
            ['error' => 'internal_error', 'hint' => $e->getMessage()],
            JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES
        );
    }
    exit(1);
});
