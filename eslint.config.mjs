// ЛІНТЕР СТОРІНКИ · єдина перевірка, яка читає JavaScript як мову.
//
// До 2026-09-21 ~2 250 рядків коду сторінки не перевіряло НІЩО. Синтаксичну
// поломку опосередковано ловили три node-тести, які цей код виконують, а все
// решта · звернення до неоголошеної змінної, друкарська помилка в імені поля,
// мертвий код · проїжджало мовчки. Для набору, де основний інтерфейс власника
// це браузер, саме тут була найбільша діра.
//
// ПРАВИЛА ПІДІБРАНІ ПІД НАЯВНИЙ КОД, А НЕ НАВПАКИ. Сторінка свідомо написана
// без складання й без модулів: класичний скрипт, `var`, підтримка старих
// браузерів. Лінтер не має права вимагати іншого стилю · він тут ловить
// ПОМИЛКИ, а не смаки.
export default [
    {
        files: ['web/**/*.js'],
        languageOptions: {
            ecmaVersion: 2019,
            sourceType: 'script',
            // Перелік браузерного оточення НАЗВАНИЙ ЯВНО. Готовий пакет
            // `globals` додав би ще одну залежність заради списку імен, а
            // «дозволити все» перетворило б правило про неоголошену змінну на
            // декорацію · саме воно тут найцінніше.
            globals: {
                window: 'readonly',
                document: 'readonly',
                console: 'readonly',
                location: 'readonly',
                history: 'readonly',
                navigator: 'readonly',
                localStorage: 'readonly',
                sessionStorage: 'readonly',
                fetch: 'readonly',
                alert: 'readonly',
                confirm: 'readonly',
                setTimeout: 'readonly',
                clearTimeout: 'readonly',
                setInterval: 'readonly',
                clearInterval: 'readonly',
                requestAnimationFrame: 'readonly',
                cancelAnimationFrame: 'readonly',
                EventSource: 'readonly',
                MutationObserver: 'readonly',
                getComputedStyle: 'readonly',
                CSS: 'readonly',
                ResizeObserver: 'readonly',
                prompt: 'readonly',
                performance: 'readonly',
                URL: 'readonly',
                URLSearchParams: 'readonly',
                Node: 'readonly',
                Image: 'readonly',
                Event: 'readonly',
                CustomEvent: 'readonly',
                AbortController: 'readonly',
                Blob: 'readonly',
                FormData: 'readonly',
                Promise: 'readonly',
                JSON: 'readonly',
                Math: 'readonly',
                Date: 'readonly',
                Intl: 'readonly',
            },
        },
        linterOptions: {
            // Невикористане вимкнення правила · теж брехня про код.
            reportUnusedDisableDirectives: 'error',
        },
        rules: {
            // Головне заради чого все: імʼя, якого немає.
            'no-undef': 'error',
            // `catch (e) {}` у цьому коді НАВМИСНЕ: доступ до сховища
            // браузера падає в приватному режимі, і там нема чого робити,
            // окрім як не впасти. Тому змінна помилки з-під правила виведена,
            // а от невикористана ФУНКЦІЯ чи змінна лишається помилкою · на
            // першому ж прогоні саме так знайшлась мертва `unescapeJsonString`.
            'no-unused-vars': ['error', { args: 'none', caughtErrors: 'none' }],
            'no-redeclare': 'error',
            'no-dupe-keys': 'error',
            'no-dupe-args': 'error',
            'no-duplicate-case': 'error',
            'no-unreachable': 'error',
            'no-fallthrough': 'error',
            'no-cond-assign': 'error',
            'no-constant-condition': 'error',
            'no-self-assign': 'error',
            'no-sparse-arrays': 'error',
            'no-func-assign': 'error',
            'no-obj-calls': 'error',
            'use-isnan': 'error',
            'valid-typeof': 'error',
            // `==` у цьому коді вживається свідомо (`== null` як «null або
            // undefined»), тому правило не вмикається: воно дало б десятки
            // зауважень там, де помилки немає.
            eqeqeq: 'off',
        },
    },
];
