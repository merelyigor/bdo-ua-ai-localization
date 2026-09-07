<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli;

/**
 * Вивід CLI-команд у stdout/stderr із безпечним визначенням термінала.
 *
 * Колір є властивістю поверхні виводу, а не команди: у pipe або на Windows
 * ANSI-послідовності не додаються, тому машинний вивід не псується.
 */
final class Output
{
    /** @var resource */
    private $stdout;

    /** @var resource */
    private $stderr;

    private readonly bool $terminal;

    public function __construct(mixed $stdout = null, mixed $stderr = null)
    {
        $this->stdout = $stdout ?? $this->openDefault('stdout');
        $this->stderr = $stderr ?? $this->openDefault('stderr');
        $this->terminal = $this->detectTerminal();
    }

    /** Надрукувати текст у stdout без зміни його байтів. */
    public function stdout(string $text): void
    {
        $this->write($this->stdout, $text);
    }

    /** Надрукувати текст у stderr без зміни його байтів. */
    public function stderr(string $text): void
    {
        $this->write($this->stderr, $text);
    }

    /** Додати ANSI-колір лише для інтерактивного stdout. */
    public function color(string $text, string $sequence): string
    {
        if (! $this->terminal) {
            return $text;
        }

        return "\033[{$sequence}m{$text}\033[0m";
    }

    /** @param resource $stream */
    private function write(mixed $stream, string $text): void
    {
        if (is_resource($stream)) {
            fwrite($stream, $text);
        }
    }

    /** @return resource */
    private function openDefault(string $name)
    {
        $stream = fopen('php://'.$name, 'wb');
        if ($stream === false) {
            throw new \RuntimeException('не вдалося відкрити php://'.$name);
        }

        return $stream;
    }

    private function detectTerminal(): bool
    {
        if (! defined('STDOUT')) {
            return false;
        }
        if (function_exists('stream_isatty')) {
            try {
                return @stream_isatty(STDOUT);
            } catch (\Throwable) {
                return false;
            }
        }
        if (function_exists('posix_isatty')) {
            try {
                return @posix_isatty(STDOUT);
            } catch (\Throwable) {
                return false;
            }
        }

        return false;
    }
}
