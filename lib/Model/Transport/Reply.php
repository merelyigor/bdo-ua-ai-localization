<?php

declare(strict_types=1);

namespace Bdo\Translate\Model\Transport;

/**
 * Зібрана відповідь моделі · КАНОНІЧНА форма, однакова для всіх провайдерів.
 *
 * Навіщо окремий обʼєкт. Перевірки, які коштували прогонів (`done_reason`,
 * порожній `content`, `not_json`, лічильники, вікно), мусять лишитись в
 * ОДНОМУ місці · у клієнті. Якби кожен транспорт віддавав свою форму, ці
 * перевірки довелось би подвоїти, а подвоєна перевірка розходиться: одна
 * половина ловить обрив, друга ні, і це видно лише на живому прогоні.
 *
 * Тому транспорт відповідає рівно за ПРОТОКОЛ (NDJSON проти SSE, назви полів,
 * заголовки), а зміст оцінює той самий код, що й раніше.
 */
final class Reply
{
    /**
     * @param  string  $content    текст відповіді (для нас · JSON під схемою)
     * @param  string  $thinking   роздуми, якщо провайдер їх віддає окремо
     * @param  string  $doneReason `stop` · норма; будь-що інше · обрив
     * @param  int|null  $in       токенів на вході за версією провайдера
     * @param  int|null  $out      токенів на виході
     * @param  int  $chunks        скільки чанків прийшло потоком (0 · без потоку)
     */
    public function __construct(
        public readonly string $content,
        public readonly string $thinking = '',
        public readonly string $doneReason = '',
        public readonly ?int $in = null,
        public readonly ?int $out = null,
        public readonly int $chunks = 0,
    ) {}
}
