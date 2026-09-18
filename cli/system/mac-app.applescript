-- Значок BDO у Dock · ДЖЕРЕЛО. Зібраний бандл лежить у `BDO.app`, збирає його
-- `scripts/build-mac-app.sh`.
--
-- ЧОМУ ЦЕ APPLESCRIPT, А НЕ SHELL-СКРИПТ У БАНДЛІ.
-- Бандл, чий виконуваний файл є звичайним скриптом, ніколи не відкриває
-- зʼєднання з WindowServer, тому LaunchServices не вважає запуск завершеним:
-- значок у Dock СТРИБАЄ БЕЗКІНЕЧНО (виявлено власником 2026-09-06, D91).
-- Перевірено на двох однакових бандлах поспіль: `lsappinfo` показує
-- `!cgsConnection` у скриптового й не показує в applet. Applet · справжній
-- застосунок: реєструється, стоїть у Dock, приймає «Завершити» й Cmd+Q.
--
-- ЛОГІКИ ТУТ НЕМАЄ Й БУТИ НЕ МАЄ. Усе робить PHP-команда `mac-app`; тут лише
-- три звертання до неї.
--
-- PATH ЗАДАЄТЬСЯ ПРЯМО В РЯДКУ, А НЕ ОКРЕМИМ СКРИПТОМ. LaunchServices стартує
-- бандл без термінального PATH, і `php` тоді не знаходиться. Раніше це лагодив
-- `cli/system/gui-path.sh`, який доводилось SOURCE-ити в оболонку · саме через
-- нього bash лишався на шляху запуску застосунку. AppleScript однаково вміє
-- запускати лише через `do shell script`, тому дешевше назвати типові теки
-- Homebrew тут одним рядком, ніж тримати заради цього окремий скрипт.

property repoRoot : ""
property bdoPath : "/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

on bdo(action)
	do shell script "PATH=" & quoted form of bdoPath & " exec php " & quoted form of (repoRoot & "/cli/bdo.php") & " mac-app " & action
end bdo

-- Тека набору береться від розташування САМОГО бандла, тому `BDO.app` мусить
-- лишатись у теці набору. Dock тримає посилання на оригінал · перетягувати
-- можна, копіювати кудись інде · ні.
on locateRepo()
	set myPath to POSIX path of (path to me)
	if myPath ends with "/" then set myPath to text 1 thru -2 of myPath
	set repoRoot to do shell script "dirname " & quoted form of myPath
end locateRepo

on run
	locateRepo()
	try
		bdo("start")
	on error msg
		display dialog "Не вдалося підняти інтерфейс." & return & return & msg ¬
			with title "BDO Локалізація" buttons {"Зрозуміло"} default button 1
		quit
	end try
end run

-- Значок живий, поки живий сервер. Зупинили інтерфейс інакше (термінал,
-- `make web-stop`) · значок зникає з Dock, а не обіцяє роботу, якої немає.
on idle
	try
		bdo("alive")
	on error
		quit
	end try
	return 2
end idle

-- ЗАКРИВ ЗНАЧОК · ЗУПИНИВСЯ ІНТЕРФЕЙС. Вимога власника 2026-09-06.
on quit
	try
		bdo("stop")
	end try
	continue quit
end quit
