<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Quality;

use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\Output;
use RuntimeException;

/**
 * Накладає правки ролі за АДРЕСОЮ · заміна шматка, а не переданий текст.
 *
 * Спільна для ДВОХ кроків: підстановки назв і ремонту після якості. Обидва
 * міняють у рядку названі місця, тому спосіб накладання в них один.
 *
 * ЧОМУ НЕ `merge`. Роль `translation-names` раніше повертала повний текст
 * рядка, і це коштувало двічі. Ціна перша · вихід: заміряно на живій пачці
 * `20260905_210828`, поле `current` займало 54.5% запиту, а модель
 * ПЕРЕДРУКОВУВАЛА весь рядок заради однієї назви (1 626 вихідних токенів на три
 * рядки). Ціна друга й важливіша · довіра: у передрукованому тексті
 * плейсхолдери, PA markup, переноси й довжину доводилось перевіряти ПІСЛЯ
 * моделі, бо зіпсувати вона могла будь-що.
 *
 * Тепер роль каже лише `find` і `replace`, а текст міняє код. Решта рядка
 * лишається цілою ЗА ПОБУДОВОЮ, а не за результатом перевірки.
 *
 * НЕ ЗНАЙШЛИ `find` · рядок лишається як був. Це не тиха втрата: кожен такий
 * випадок називається в stderr і рахується в підсумку, тому «модель вигадала
 * місце» видно одразу, а пачка через це не спиняється.
 */
final class ApplyEditsCommand implements Command, \Bdo\Translate\Cli\CommandHelp
{
    public function execute(array $arguments, Output $output): int
    {
        $baseFile = $this->required($arguments, 0, 'Потрібен кандидат пачки (final-candidate.json або heal-merged.json)');
        $editsFile = $this->required($arguments, 1, 'Потрібен файл правок від ролі (names-fixes.json або fixes.json)');
        $outputFile = $this->required($arguments, 2, 'Потрібен вихідний файл');

        $base = json_decode((string) file_get_contents($baseFile), true, 512, JSON_THROW_ON_ERROR);
        $edits = json_decode((string) file_get_contents($editsFile), true, 512, JSON_THROW_ON_ERROR);
        if (! is_array($base) || ! is_array($edits)) {
            throw new RuntimeException('Обидва файли мусять бути масивами');
        }
        $index = [];
        foreach ($base as $position => $item) {
            $hash = is_array($item) ? (string) ($item['identity_hash'] ?? '') : '';
            if ($hash !== '') {
                $index[$hash] = $position;
            }
        }

        $applied = 0;
        $missed = 0;
        foreach ($edits as $edit) {
            if (! is_array($edit)) {
                throw new RuntimeException('Елемент правки не є обʼєктом');
            }
            $hash = (string) ($edit['identity_hash'] ?? '');
            $find = (string) ($edit['find'] ?? '');
            $replace = (string) ($edit['replace'] ?? '');
            if (! isset($index[$hash])) {
                throw new RuntimeException("Чужий identity_hash у правці: {$hash}");
            }
            // ПОРОЖНЄ Й ТОТОЖНЕ · НЕ ПРАВКА. Порожній `find` замінив би кожну
            // межу символу, тотожна пара просто витратила б виклик.
            if (trim($find) === '' || $find === $replace) {
                $missed++;
                $output->stderr(sprintf("  %s  порожня або тотожна правка\n", substr($hash, 0, 12)));
                continue;
            }
            $text = (string) ($base[$index[$hash]]['text'] ?? '');
            if (! str_contains($text, $find)) {
                // ВІДКАТ НА ПОТОЧНУ ПОВЕДІНКУ · рядок їде без цієї підстановки.
                $missed++;
                $output->stderr(sprintf("  %s  у тексті немає «%s»\n", substr($hash, 0, 12), mb_substr($find, 0, 60)));
                continue;
            }
            $base[$index[$hash]]['text'] = str_replace($find, $replace, $text);
            $applied++;
        }
        if ($applied === 0 && $missed === 0 && $edits !== []) {
            throw new RuntimeException('Жодної правки не розібрано · формат відповіді ролі не той');
        }
        file_put_contents($outputFile, json_encode($base, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT | JSON_THROW_ON_ERROR));
        $output->stdout(sprintf("Накладено правок: %d | не знайдено місця: %d\n", $applied, $missed));

        return 0;
    }

    /** @param list<mixed> $arguments */
    private function required(array $arguments, int $index, string $message): string
    {
        $value = (string) ($arguments[$index] ?? '');
        if ($value === '') {
            throw new RuntimeException($message);
        }
        if (! is_file($value) && $index < 2) {
            throw new RuntimeException("Немає файлу: {$value}");
        }

        return $value;
    }

    /** Повернути дослівну довідку legacy-маршруту. */
    public static function help(): string
    {
        return <<<'BDO_HELP_TEXT'
Накласти правки ролі назв на кандидата пачки.

  ./bdo apply-edits final-candidate.json names-fixes.json out.json
  ./bdo apply-edits heal-merged.json fixes.json healed.json

Ролі `translation-names` і `translation-repair` повертають АДРЕСУ правки
(`find` і `replace`), а не текст рядка. Заміну робить ця команда, тому все поза названим шматком лишається цілим
за побудовою: плейсхолдери, PA markup, переноси й довжину не треба довіряти
моделі й перевіряти після неї.

Не знайдено `find` у тексті · рядок лишається без змін, випадок названо в stderr
і враховано в підсумку. Чужий identity_hash зупиняє команду.

BDO_HELP_TEXT;
    }
}
