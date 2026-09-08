<?php

declare(strict_types=1);

/**
 * Сумісна точка входу для колишнього http-request.sh.
 *
 * Аргументи лишаються у формі curl-викликачів, але виконання переходить у
 * ext-curl через Bdo\Translate\Http\Client, щоб зовнішній процес зник із шляху.
 */
require_once dirname(__DIR__, 2).'/lib/autoload.php';

use Bdo\Translate\Http\Client;
use Bdo\Translate\Http\Request;

$options = [
    'fail' => false,
    'silent' => false,
    'show_error' => false,
    'method' => null,
    'headers' => [],
    'body' => null,
    'has_body' => false,
    'output' => null,
    'write_out' => null,
    'max_time' => 30,
    'connect_timeout' => 10,
    'follow' => false,
];
$urls = [];
$arguments = array_slice($argv, 1);

$error = static function (string $message, int $code = 2) use (&$options): never {
    if (! $options['silent'] || $options['show_error']) {
        fwrite(STDERR, "http-client: {$message}\n");
    }
    exit($code);
};
$value = static function (int &$index, array $arguments, string $option) use ($error): string {
    $index++;
    if (! isset($arguments[$index])) {
        $error($option.' потребує значення');
    }

    return (string) $arguments[$index];
};
$setShortFlags = static function (string $argument) use (&$options, $error): void {
    foreach (str_split(substr($argument, 1)) as $flag) {
        if ($flag === 'f') {
            $options['fail'] = true;
        } elseif ($flag === 's') {
            $options['silent'] = true;
        } elseif ($flag === 'S') {
            $options['show_error'] = true;
        } elseif ($flag === 'L') {
            $options['follow'] = true;
        } else {
            $error('невідомий прапорець: -'.$flag);
        }
    }
};

for ($index = 0, $count = count($arguments); $index < $count; $index++) {
    $argument = (string) $arguments[$index];
    if ($argument === '--') {
        for ($index++; $index < $count; $index++) {
            $urls[] = (string) $arguments[$index];
        }
        break;
    }
    if ($argument === '' || $argument[0] !== '-') {
        $urls[] = $argument;
        continue;
    }
    if ($argument[0] === '-' && ! str_starts_with($argument, '--') && strlen($argument) > 2) {
        $setShortFlags($argument);
        continue;
    }
    switch ($argument) {
        case '-f':
            $options['fail'] = true;
            break;
        case '-s':
            $options['silent'] = true;
            break;
        case '-S':
            $options['show_error'] = true;
            break;
        case '-L':
        case '--location':
            $options['follow'] = true;
            break;
        case '-X':
            $options['method'] = strtoupper($value($index, $arguments, '-X'));
            break;
        case '-H':
            $options['headers'][] = $value($index, $arguments, '-H');
            break;
        case '-d':
        case '--data':
        case '--data-raw':
        case '--data-binary':
            $data = $value($index, $arguments, $argument);
            if (str_starts_with($data, '@')) {
                $path = substr($data, 1);
                $data = @file_get_contents($path);
                if ($data === false) {
                    $error('не вдалося прочитати тіло запиту: '.$path);
                }
            }
            if ($options['has_body'] && $argument !== '--data-binary') {
                $options['body'] .= '&'.$data;
            } else {
                $options['body'] = $data;
            }
            $options['has_body'] = true;
            break;
        case '-o':
            $options['output'] = $value($index, $arguments, '-o');
            break;
        case '-w':
            $options['write_out'] = $value($index, $arguments, '-w');
            break;
        case '-m':
        case '--max-time':
            $options['max_time'] = max(1, (int) $value($index, $arguments, $argument));
            break;
        case '--connect-timeout':
            $options['connect_timeout'] = max(1, (int) $value($index, $arguments, $argument));
            break;
        default:
            $error('невідомий прапорець: '.$argument);
    }
}

if (count($urls) !== 1 || trim($urls[0]) === '') {
    $error('потрібен рівно один непорожній URL');
}

$method = $options['method'] ?? ($options['has_body'] ? 'POST' : 'GET');
$request = new Request($method, $urls[0], $options['headers'], $options['has_body'] ? $options['body'] : null);
$client = new Client(null, $options['max_time'], $options['connect_timeout']);

try {
    $response = $client->send(
        $request,
        $options['output'] === '-' ? null : $options['output'],
        $options['fail'],
        $options['follow'],
    );
} catch (Throwable $exception) {
    $code = (int) $exception->getCode();
    $error($exception->getMessage(), $code > 0 && $code < 256 ? $code : 1);
}

if ($options['output'] === null || $options['output'] === '-') {
    fwrite(STDOUT, $response->body);
}
if ($options['write_out'] !== null) {
    fwrite(STDOUT, str_replace('%{http_code}', (string) $response->statusCode, $options['write_out']));
}
if ($options['fail'] && $response->statusCode >= 400) {
    if (! $options['silent'] || $options['show_error']) {
        $message = $response->transportError !== '' ? $response->transportError : 'HTTP '.$response->statusCode;
        fwrite(STDERR, "http-client: {$message}\n");
    }
    exit(22);
}

exit(0);
