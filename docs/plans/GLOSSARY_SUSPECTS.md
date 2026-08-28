# Підозрілі записи глосарію

Згенеровано `./bdo suspects` з реєстру термінів, які реально трапились у
прогонах (`state/term-notes-queue.json`). Це НЕ вирок: глосарій лишається
законом, а тут лише перелік записів, які на вигляд помилкові й потребують
людини. Жоден запис не змінено · зміна глосарію є рішенням власника.

Позначені терміни поки не подаються моделі як обовʼязкові й не викидають
приклади: помилковий закон псує кожен рядок, де трапився термін.

ОХОПЛЕННЯ · весь глосарій, зчитаний сторінками через
`GET /glossary/terms/list`.

Класи підозр:

- `latin_target_mismatch` · у полі українського відповідника стоїть ІНШИЙ
  латинський рядок (`FTP -> QZG`, `Bilson -> Kiraki`) · майже напевно
  переплутані записи; такий термін не подається моделі;
- `time_unit_mismatch` · одиниця часу перекладена іншою одиницею часу;
- `function_word` · займенник або визначник як обовʼязковий термін;
- `untranslated_target` · відповідник збігається з оригіналом з точністю до
  регістру · шкоди немає, тому модель його бачить, це лише до відома.

Дослівний збіг (`AP -> AP`) і політика `keep_source` підозрою не є: це
свідоме «не перекладати». Правила «один відповідник на кілька термінів»
немає навмисно · на повному каталозі таких 47 205 із 136 022 (35%), це
нормальні варіанти предметів, а не дефект.

| Термін | Відповідник | Клас | Чому | Разів | Приклад рядка |
|---|---|---|---|---|---|
| `Explorer to Conqueror Pack` | `Explorer to Conqueror Package` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `[NOR] [Event] 2nd Anniversary Love` | `Other` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `[NOR] [Event] 2nd Anniversary Thanks` | `Other` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `[NOR] [Event] Together until the 100th Anniversary!` | `Other` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `Essential Package (Taiwan)` | `Essential Package` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `Gladius` | `Labour Day` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `We are Family` | `We are family` | untranslated_target | відповідник збігається з оригіналом з точністю до регістру | 0 |  |
| `I Can Show You the World` | `I can show you the world` | untranslated_target | відповідник збігається з оригіналом з точністю до регістру | 0 |  |
| `<PAColor0xFFFF6C00>Seasonal Sensation!<PAOldColor>` | `All Saints' Day` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `I Like to Move It, Move It!` | `I like to move it, move it!` | untranslated_target | відповідник збігається з оригіналом з точністю до регістру | 0 |  |
| `Triathlete` | `Get movin` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `Take my heart, not my mobs` | `xoxo` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `GM Quartz` | `GM White` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `Her` | `Вона` | function_word | займенник або визначник не має одного обовʼязкового відповідника | 0 |  |
| `Bilson` | `Kiraki` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `NoNMercy` | `DuoTheFold` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `Hatehatehate1` | `NotCoco` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `TILLTHISDAY` | `Znmop` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `Exceltior` | `Animusphere` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `Mayhem` | `Quix` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `KilI` | `GaOoY0` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `Shiuu` | `Lewd` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `Avi` | `KingGopp` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `Leyukisa` | `Krouwn` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `IRagey` | `MeStrokerMeFight` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `Lua` | `Virtuus` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `Nosyo` | `IRagey` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `Oribu` | `Kedi_EU` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `Vaphroy` | `ChampionFighter` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `Kekspear` | `Lafuce` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `CarI` | `Exceltior` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `REFUCHS` | `Inoqx` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `Chengmang` | `Aserbin` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `LUK114` | `Niyon` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `Precision` | `Hakurenn` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `Dreamnail` | `DMNK` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `Stwarcrossed` | `Starcrossed` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `Hygaa` | `CCaJJ` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `Saffe` | `Bumbumbini` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `Killerbit` | `Cakes` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `Pachimu` | `DuoFold` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `Imsonic` | `IamGerrit` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `HOTl` | `FreeMouseMove` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `FFrame` | `BRNY` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `FTP` | `QZG` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `ForestHunter` | `RonaldJ` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `Pandinha` | `Choice` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `Curvi` | `Calb` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `EmanueI` | `HeartKing` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `YellowHeart` | `Ratrospec` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `Lactatemilkshake` | `Shikio` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `Ioopy` | `Mehguh` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `SirChimi` | `Savantelle` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `Rhya` | `Yuike` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `Anasui` | `Multimeltor` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `DeathsGrip` | `Ehsap` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `Miss` | `Whiskey0` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `BelIy` | `DomFeng` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `Phabi` | `Huntler` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `DisPearBruh` | `CanadianCorgi` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `VeiVei` | `Nosoren` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffe9bd23>[10+10]<PAOldColor> Gilded Treasure Chest` | `<PAColor0xffe9bd23>[10+10]<PAOldColor>Gilded Treasure Chest` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffe9bd23>[Blessing of Cron Stones]<PAOldColor> Special Pearl Box` | `<PAColor0xffe9bd23>[Blessing of Cron Stones]<PAOldColor>Special Pearl Box` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffe9bd23>[30% DC]<PAOldColor> Coupon and Pearl Box III` | `<PAColor0xffe9bd23>[30% DC]<PAOldColor>Coupon and Pearl Box III` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffe9bd23>[20% DC]<PAOldColor> Coupon and Pearl Box II` | `<PAColor0xffe9bd23>[20% DC]<PAOldColor>Coupon and Pearl Box II` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffe9bd23>[10% DC]<PAOldColor> Coupon and Pearl Box I` | `<PAColor0xffe9bd23>[10% DC]<PAOldColor>Coupon and Pearl Box I` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffff99ff>[10 Years 3+3]<PAOldColor> Choose Your Sweet Journey Box x3` | `<PAColor0xffff99ff>[10 Years 3+3]<PAOldColor>Choose Your Sweet Journey Box x3` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffff99ff>[10 Years 3+3]<PAOldColor> Wizard Gosphy x3` | `<PAColor0xffff99ff>[10 Years 3+3]<PAOldColor>Wizard Gosphy x3` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffff99ff>[10 Years 3+3]<PAOldColor> Maid for Hire Box x3` | `<PAColor0xffff99ff>[10 Years 3+3]<PAOldColor>Maid for Hire Box x3` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffff99ff>[10 Years 3+3]<PAOldColor> Mysterious Treasure Chest x3` | `<PAColor0xffff99ff>[10 Years 3+3]<PAOldColor>Mysterious Treasure Chest x3` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffff99ff>[10 Years 3+3]<PAOldColor> Sweet Premium Enhancement Box x3` | `<PAColor0xffff99ff>[10 Years 3+3]<PAOldColor>Sweet Premium Enhancement Box x3` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffff99ff>[10 Years]<PAOldColor> Secret Book of Old Moon (90 Days)` | `<PAColor0xffff99ff>[10 Years]<PAOldColor>Secret Book of Old Moon (90 Days)` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffff99ff>[10 Years]<PAOldColor> Blessing of Kamasylve (90 Days)` | `<PAColor0xffff99ff>[10 Years]<PAOldColor>Blessing of Kamasylve (90 Days)` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffff99ff>[10 Years]<PAOldColor> Value Pack (90 Days)` | `<PAColor0xffff99ff>[10 Years]<PAOldColor>Value Pack (90 Days)` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffff99ff>[10 Years]<PAOldColor> Blessing of Old Moon Pack (90 Days)` | `<PAColor0xffff99ff>[10 Years]<PAOldColor>Blessing of Old Moon Pack (90 Days)` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffff99ff>[10 Years 100 Pearls]<PAOldColor> Naderr's Parchment x1` | `<PAColor0xffff99ff>[10 Years 100 Pearls]<PAOldColor>Naderr's Parchment x1` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffff99ff>[10 Years 100 Pearls]<PAOldColor> Elion's Blessing x10` | `<PAColor0xffff99ff>[10 Years 100 Pearls]<PAOldColor>Elion's Blessing x10` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffff99ff>[10 Years 100 Pearls]<PAOldColor> Item Brand Spell Stone x2` | `<PAColor0xffff99ff>[10 Years 100 Pearls]<PAOldColor>Item Brand Spell Stone x2` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffff99ff>[10 Years 100 Pearls]<PAOldColor> Inventory +4 Expansion Coupon` | `<PAColor0xffff99ff>[10 Years 100 Pearls]<PAOldColor>Inventory +4 Expansion Coupon` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffff99ff>[10 Years 100 Pearls]<PAOldColor> Gleaming Adventure Box x1` | `<PAColor0xffff99ff>[10 Years 100 Pearls]<PAOldColor>Gleaming Adventure Box x1` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffff99ff>[10 Years 100 Pearls]<PAOldColor> Intriguing Adventure Box x2` | `<PAColor0xffff99ff>[10 Years 100 Pearls]<PAOldColor>Intriguing Adventure Box x2` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffff99ff>[10 Years 100 Pearls]<PAOldColor> Mystical Cron Stone Bundle x1` | `<PAColor0xffff99ff>[10 Years 100 Pearls]<PAOldColor>Mystical Cron Stone Bundle x1` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffff99ff>[10 Years]<PAOldColor> Triple Premium Pack` | `<PAColor0xffff99ff>[10 Years]<PAOldColor>Triple Premium Pack` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffff99ff>[10 Years]<PAOldColor> Hepta-Premium Pack` | `<PAColor0xffff99ff>[10 Years]<PAOldColor>Hepta-Premium Pack` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffff99ff>[10 Years]<PAOldColor> Prestige Outfit Pack` | `<PAColor0xffff99ff>[10 Years]<PAOldColor>Prestige Outfit Pack` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffe9bd23>[Charred Soul]<PAOldColor> All-in-One Pack` | `<PAColor0xffe9bd23>[Charred Soul]<PAOldColor>All-in-One Pack` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffe9bd23>[Charred Soul]<PAOldColor> Premium Outfit Pack` | `<PAColor0xffe9bd23>[Charred Soul]<PAOldColor>Premium Outfit Pack` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffe9bd23>[Charred Soul]<PAOldColor> Sweet Premium Pack` | `<PAColor0xffe9bd23>[Charred Soul]<PAOldColor>Sweet Premium Pack` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffe9bd23>[Charred Soul]<PAOldColor> Ultimate Premium Pack` | `<PAColor0xffe9bd23>[Charred Soul]<PAOldColor>Ultimate Premium Pack` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffff99ff>[10 Years]<PAOldColor> [10+10] Blacksmith's Shiny Box` | `<PAColor0xffff99ff>[10 Years]<PAOldColor>[10+10] Blacksmith's Shiny Box` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffff99ff>[10 Years]<PAOldColor> [-60%] Premium Enhancement Pack` | `<PAColor0xffff99ff>[10 Years]<PAOldColor>[-60%] Premium Enhancement Pack` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffff99ff>[10 Years]<PAOldColor> Sweet Journey Pack` | `<PAColor0xffff99ff>[10 Years]<PAOldColor>Sweet Journey Pack` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffff99ff>[10 Years]<PAOldColor> Anniversary Thank You Pack` | `<PAColor0xffff99ff>[10 Years]<PAOldColor>Anniversary Thank You Pack` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffff99ff>[10 Years]<PAOldColor> Radiant Adventure Support Pack` | `<PAColor0xffff99ff>[10 Years]<PAOldColor>Radiant Adventure Support Pack` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffff99ff>[10 Years 100 Pearls]<PAOldColor> Choose Your Resplendent Storage Box x2` | `<PAColor0xffff99ff>[10 Years 100 Pearls]<PAOldColor>Choose Your Resplendent Storage Box x2` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffff99ff>[10 Years 100 Pearls]<PAOldColor> Blessing of Old Moon Pack (3 Days)` | `<PAColor0xffff99ff>[10 Years 100 Pearls]<PAOldColor>Blessing of Old Moon Pack (3 Days)` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffff99ff>[10 Years]<PAOldColor> Penta-Premium Outfit Pack` | `<PAColor0xffff99ff>[10 Years]<PAOldColor>Penta-Premium Outfit Pack` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffe9bd23>[Charred Soul]<PAOldColor> Blessing of Old Moon Pack (7 Days)` | `<PAColor0xffe9bd23>[Charred Soul]<PAOldColor>Blessing of Old Moon Pack (7 Days)` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffe9bd23>[Charred Soul]<PAOldColor> Triple Dark Prince Set` | `<PAColor0xffe9bd23>[Charred Soul]<PAOldColor>Triple Dark Prince Set` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffff99ff>[10 Years]<PAOldColor> Choose Your Maid Box x5` | `<PAColor0xffff99ff>[10 Years]<PAOldColor>Choose Your Maid Box x5` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffff99ff>[10 Years]<PAOldColor> Secret Scroll of Pure Equilibrium` | `<PAColor0xffff99ff>[10 Years]<PAOldColor>Secret Scroll of Pure Equilibrium` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffff99ff>[10 Years]<PAOldColor> [1+1] Classic Outfit Box` | `<PAColor0xffff99ff>[10 Years]<PAOldColor>[1+1] Classic Outfit Box` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffff99ff>[10 Years]<PAOldColor> [1+1] Premium Outfit Box` | `<PAColor0xffff99ff>[10 Years]<PAOldColor>[1+1] Premium Outfit Box` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffff99ff>[10 Years]<PAOldColor> [Bonus] Special Pearl Box` | `<PAColor0xffff99ff>[10 Years]<PAOldColor>[Bonus] Special Pearl Box` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffff99ff>[10 Years]<PAOldColor> [1+1] Pearl Box III` | `<PAColor0xffff99ff>[10 Years]<PAOldColor>[1+1] Pearl Box III` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffff99ff>[10 Years]<PAOldColor> [1+1] Pearl Box II` | `<PAColor0xffff99ff>[10 Years]<PAOldColor>[1+1] Pearl Box II` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffff99ff>[10 Years]<PAOldColor> [1+1] Pearl Box I` | `<PAColor0xffff99ff>[10 Years]<PAOldColor>[1+1] Pearl Box I` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffe9bd23>[1 Week Only]<PAOldColor> Life Focus` | `<PAColor0xffe9bd23>[1 Week Only]<PAOldColor>Life Focus` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffe9bd23>[1 Week Only]<PAOldColor> Combat Focus` | `<PAColor0xffe9bd23>[1 Week Only]<PAOldColor>Combat Focus` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffff99ff>[10 Years]<PAOldColor> Transcended Premium Enhancement Box x5` | `<PAColor0xffff99ff>[10 Years]<PAOldColor>Transcended Premium Enhancement Box x5` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffff99ff>[10 Years 3+3]<PAOldColor> Choose Your Resplendent Storage Box x3` | `<PAColor0xffff99ff>[10 Years 3+3]<PAOldColor>Choose Your Resplendent Storage Box x3` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffff99ff>[10 Years 3+3]<PAOldColor> Pet Skill Change Coupon x3` | `<PAColor0xffff99ff>[10 Years 3+3]<PAOldColor>Pet Skill Change Coupon x3` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffff99ff>[10 Years 3+3]<PAOldColor> Mount Level Down Ticket x3` | `<PAColor0xffff99ff>[10 Years 3+3]<PAOldColor>Mount Level Down Ticket x3` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffff99ff>[10 Years 3+3]<PAOldColor> Mount Skill Change Coupon x3` | `<PAColor0xffff99ff>[10 Years 3+3]<PAOldColor>Mount Skill Change Coupon x3` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `[Class 1 Silver Item] Olvia Academy Pass - Sailing/Barter` | `<PAColor0xffe9bd23>[Class 1 Silver Item]<PAOldColor>Olvia Academy Pass - Sailing/Barter` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `[Class 1 Silver Item] Olvia Academy Pass - Training` | `<PAColor0xffe9bd23>[Class 1 Silver Item]<PAOldColor>Olvia Academy Pass - Training` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `[Class 1 Silver Item] Olvia Academy Pass - Processing` | `<PAColor0xffe9bd23>[Class 1 Silver Item]<PAOldColor>Olvia Academy Pass - Processing` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `[Class 1 Silver Item] Olvia Academy Pass - Alchemy` | `<PAColor0xffe9bd23>[Class 1 Silver Item]<PAOldColor>Olvia Academy Pass - Alchemy` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `[Class 1 Silver Item] Olvia Academy Pass - Cooking` | `<PAColor0xffe9bd23>[Class 1 Silver Item]<PAOldColor>Olvia Academy Pass - Cooking` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `[Class 1 Silver Item] Olvia Academy Pass - Hunting` | `<PAColor0xffe9bd23>[Class 1 Silver Item]<PAOldColor>Olvia Academy Pass - Hunting` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `[Class 1 Silver Item] Olvia Academy Pass - Fishing` | `<PAColor0xffe9bd23>[Class 1 Silver Item]<PAOldColor>Olvia Academy Pass - Fishing` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `[Class 1 Silver Item] Olvia Academy Pass - Gathering` | `<PAColor0xffe9bd23>[Class 1 Silver Item]<PAOldColor>Olvia Academy Pass - Gathering` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `[Class 1 Silver Item] Olvia Academy Pass - Farming` | `<PAColor0xffe9bd23>[Class 1 Silver Item]<PAOldColor>Olvia Academy Pass - Farming` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffe9bd23>[New/Returning]<PAOldColor> New Travel Support Pack` | `<PAColor0xffe9bd23>[New/Returning]<PAOldColor>New Travel Support Pack` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffe9bd23>[Feb 2+2]<PAOldColor> Wizard Gosphy` | `<PAColor0xffe9bd23>[Feb 2+2]<PAOldColor>Wizard Gosphy` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffe9bd23>[Feb 2+2]<PAOldColor> Choose Your Resplendent Storage Box` | `<PAColor0xffe9bd23>[Feb 2+2]<PAOldColor>Choose Your Resplendent Storage Box` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffe9bd23>[Feb 2+2]<PAOldColor> Item Brand Spell Stone` | `<PAColor0xffe9bd23>[Feb 2+2]<PAOldColor>Item Brand Spell Stone` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffe9bd23>[Feb 2+2]<PAOldColor> Artisan's Memory` | `<PAColor0xffe9bd23>[Feb 2+2]<PAOldColor>Artisan's Memory` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffe9bd23>[Feb 2+2]<PAOldColor> Gleamingly Intriguing Adventure Boxes` | `<PAColor0xffe9bd23>[Feb 2+2]<PAOldColor>Gleamingly Intriguing Adventure Boxes` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffe9bd23>[Feb 2+2]<PAOldColor> Mysterious Treasure Chest` | `<PAColor0xffe9bd23>[Feb 2+2]<PAOldColor>Mysterious Treasure Chest` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffe9bd23>[Feb 2+2]<PAOldColor> Radiant Glyph Treasure Chest` | `<PAColor0xffe9bd23>[Feb 2+2]<PAOldColor>Radiant Glyph Treasure Chest` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffe9bd23>[Feb 2+2]<PAOldColor> Choose Your Premium Outfit Box` | `<PAColor0xffe9bd23>[Feb 2+2]<PAOldColor>Choose Your Premium Outfit Box` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffe9bd23>[Feb 2+2]<PAOldColor> Pet Skill Change Coupon` | `<PAColor0xffe9bd23>[Feb 2+2]<PAOldColor>Pet Skill Change Coupon` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffe9bd23>[Feb 2+2]<PAOldColor> Classic Pet Pack` | `<PAColor0xffe9bd23>[Feb 2+2]<PAOldColor>Classic Pet Pack` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffe9bd23>[Feb 2+2]<PAOldColor> Rare Pet Pack` | `<PAColor0xffe9bd23>[Feb 2+2]<PAOldColor>Rare Pet Pack` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffff6c00>[Jan 1+1]<PAOldColor> Value Pack (15 Days)` | `<PAColor0xffff6c00>[Jan 1+1]<PAOldColor>Value Pack (15 Days)` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffff6c00>[Jan 1+1]<PAOldColor> Choose Your Resplendent Journey Box` | `<PAColor0xffff6c00>[Jan 1+1]<PAOldColor>Choose Your Resplendent Journey Box` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffff6c00>[Jan 1+1]<PAOldColor> Ultimate Premium Enhancement Box` | `<PAColor0xffff6c00>[Jan 1+1]<PAOldColor>Ultimate Premium Enhancement Box` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffff6c00>[Jan 1+1]<PAOldColor> Transcended Premium Enhancement Box` | `<PAColor0xffff6c00>[Jan 1+1]<PAOldColor>Transcended Premium Enhancement Box` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffff6c00>[Jan 1+1]<PAOldColor> Classic Outfit Box` | `<PAColor0xffff6c00>[Jan 1+1]<PAOldColor>Classic Outfit Box` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffff6c00>[Jan 1+1]<PAOldColor> Premium Outfit Box` | `<PAColor0xffff6c00>[Jan 1+1]<PAOldColor>Premium Outfit Box` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffe9bd23>[Welcome 2026]<PAOldColor> Resplendent Adventure Pack` | `<PAColor0xffe9bd23>[Welcome 2026]<PAOldColor>Resplendent Adventure Pack` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffe9bd23>[Welcome 2026]<PAOldColor> Radiant Adventure Pack` | `<PAColor0xffe9bd23>[Welcome 2026]<PAOldColor>Radiant Adventure Pack` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffe9bd23>[Welcome 2026]<PAOldColor> Gleaming 20+26 Pack` | `<PAColor0xffe9bd23>[Welcome 2026]<PAOldColor>Gleaming 20+26 Pack` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xff449ef3>[Seraph]<PAOldColor> Choose Your Holy Knight Outfit Pack II` | `<PAColor0xff449ef3>[Seraph]<PAOldColor>Choose Your Holy Knight Outfit Pack II` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xff449ef3>[Seraph]<PAOldColor> [Novice] Beginner's Aid Pack` | `<PAColor0xff449ef3>[Seraph]<PAOldColor>[Novice] Beginner's Aid Pack` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xff449ef3>[Seraph]<PAOldColor> Relics of Transcendence Pack` | `<PAColor0xff449ef3>[Seraph]<PAOldColor>Relics of Transcendence Pack` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xff449ef3>[Seraph]<PAOldColor> Radiant Treasure Pack` | `<PAColor0xff449ef3>[Seraph]<PAOldColor>Radiant Treasure Pack` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xff449ef3>[Seraph]<PAOldColor> Hero's Burden Pack` | `<PAColor0xff449ef3>[Seraph]<PAOldColor>Hero's Burden Pack` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xff449ef3>[Seraph]<PAOldColor> Choose Your Holy Knight Outfit Pack I` | `<PAColor0xff449ef3>[Seraph]<PAOldColor>Choose Your Holy Knight Outfit Pack I` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xff449ef3>[Seraph]<PAOldColor> Elion's Knight Pack` | `<PAColor0xff449ef3>[Seraph]<PAOldColor>Elion's Knight Pack` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xff449ef3>[Seraph]<PAOldColor> Elion's Calling Pack` | `<PAColor0xff449ef3>[Seraph]<PAOldColor>Elion's Calling Pack` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffe9bd23>[1+1]<PAOldColor> Forgotten Ancient Treasure Chest` | `<PAColor0xffe9bd23>[1+1]<PAOldColor>Forgotten Ancient Treasure Chest` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffe9bd23>[Loyalty]<PAOldColor> Character Slot Expansion Coupon` | `<PAColor0xffe9bd23>[Loyalty]<PAOldColor>Character Slot Expansion Coupon` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffe9bd23>[-50%]<PAOldColor> Character Slot Expansion Coupon` | `<PAColor0xffe9bd23>[-50%]<PAOldColor>Character Slot Expansion Coupon` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `[Calpheon Ball] <PAColor0xffe9bd23>[Bonus]<PAOldColor> Special Pearl Box V` | `[Calpheon Ball] <PAColor0xffe9bd23>[Bonus]<PAOldColor>Special Pearl Box V` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `[Calpheon Ball] <PAColor0xffe9bd23>[1+1]<PAOldColor> Special Pearl Box IV` | `[Calpheon Ball] <PAColor0xffe9bd23>[1+1]<PAOldColor>Special Pearl Box IV` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `[Calpheon Ball] <PAColor0xffe9bd23>[1+1]<PAOldColor> Special Pearl Box III` | `[Calpheon Ball] <PAColor0xffe9bd23>[1+1]<PAOldColor>Special Pearl Box III` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `[Calpheon Ball] <PAColor0xffe9bd23>[1+1]<PAOldColor> Special Pearl Box II` | `[Calpheon Ball] <PAColor0xffe9bd23>[1+1]<PAOldColor>Special Pearl Box II` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `[Calpheon Ball] <PAColor0xffe9bd23>[1+1]<PAOldColor> Special Pearl Box I` | `[Calpheon Ball] <PAColor0xffe9bd23>[1+1]<PAOldColor>Special Pearl Box I` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `[GM's Pick] [Hashashin] Black Desert Styles A` | `[Hashashin] Black Desert Lookbook I` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `[GM's Pick] [Deadeye] Black Desert Styles A` | `[Deadeye] Black Desert Lookbook I` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `[Halloween] Choose Your Resplendent Pack` | `<PAColor0xffff6c00>[Halloween]<PAOldColor>Choose Your Resplendent Pack` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `[Halloween] Premium Outfit Pack` | `<PAColor0xffff6c00>[Halloween]<PAOldColor>Premium Outfit Pack` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `[Halloween] All-in-One Pack` | `<PAColor0xffff6c00>[Halloween]<PAOldColor>All-in-One Pack` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `[Halloween] Ultra Premium Pack` | `<PAColor0xffff6c00>[Halloween]<PAOldColor>Ultra Premium Pack` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `[Halloween] [2+2] Sweet Premium Pack` | `<PAColor0xffff6c00>[Halloween] [2+2]<PAOldColor>Sweet Premium Pack` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `[Halloween] Blessing of Old Moon Pack (7 Days)` | `<PAColor0xffff6c00>[Halloween]<PAOldColor>Blessing of Old Moon Pack (7 Days)` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `[Halloween] Angelion & Daemonis Outfit Pack` | `<PAColor0xffff6c00>[Halloween]<PAOldColor>Angelion & Daemonis Outfit Pack` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `[Black Friday] <PAColor0xffff99ff>[2+1]<PAOldColor> Special Pearl Box` | `[Black Friday] <PAColor0xffff99ff>[2+1]<PAOldColor>Special Pearl Box` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `[Black Friday] <PAColor0xffff99ff>[40% DC Coupon]<PAOldColor> Special Pearl Box` | `[Black Friday] <PAColor0xffff99ff>[40% DC Coupon]<PAOldColor>Special Pearl Box` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `[Transcended] Sweet Premium Enhancement Box x30` | `<PAColor0xffe9bd23>[Transcended] <PAOldColor>Sweet Premium Enhancement Box x30` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `[Ultimate] Sweet Premium Enhancement Box x15` | `<PAColor0xffe9bd23>[Ultimate] <PAOldColor>Sweet Premium Enhancement Box x15` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `[Sweet] Sweet Premium Enhancement Box x5` | `<PAColor0xffe9bd23>[Sweet] <PAOldColor>Sweet Premium Enhancement Box x5` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `[1/Family] Super Premium Enhancement Pack II` | `<PAColor0xffe9bd23>[1/Family] Super Premium Enhancement Pack II<PAOldColor>` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `[1/Family] Super Premium Enhancement Pack I` | `<PAColor0xffe9bd23>[1/Family] Super Premium Enhancement Pack I<PAOldColor>` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `[1/Family] Shakatu's Resplendent Pack` | `<PAColor0xffe9bd23>[1/Family] Shakatu's Resplendent Pack<PAOldColor>` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `[Black Friday] <PAColor0xffff6c00>[20% DC Coupon]<PAOldColor> Pearl Box III` | `[Black Friday] <PAColor0xffff6c00>[20% DC Coupon]<PAOldColor>Pearl Box III` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `[Black Friday] <PAColor0xffff6c00>[30% DC Coupon]<PAOldColor> Pearl Box II` | `[Black Friday] <PAColor0xffff6c00>[30% DC Coupon]<PAOldColor>Pearl Box II` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `[Black Friday] <PAColor0xffff6c00>[40% DC Coupon]<PAOldColor> Pearl Box I` | `[Black Friday] <PAColor0xffff6c00>[40% DC Coupon]<PAOldColor>Pearl Box I` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `[GM's Pick] [Hashashin] Black Desert Styles B` | `[Hashashin] Black Desert Lookbook II` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `[GM's Pick] [Deadeye] Black Desert Styles B` | `[Deadeye] Black Desert Lookbook II` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `[1/Family] Special Convenience Pack` | `[1/Family] <PAColor0xffe9bd23>Special Convenience Pack<PAOldColor>` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `[1/Family] Special Premium Pack` | `[1/Family] <PAColor0xffe9bd23>Special Premium Pack<PAOldColor>` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `[1/Family] Special Progression Support Pack` | `[1/Family] <PAColor0xffe9bd23>Special Progression Support Pack<PAOldColor>` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `[1/Family] Ultimate Edania Pack` | `[1/Family] <PAColor0xffe9bd23>Ultimate Edania Pack<PAOldColor>` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `Bundle of 10 Energy Tonic (L)` | `Energy Tonic (L) x10 Bundle` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `[New/Returning] <PAColor0xffffff00>[Up to 3120 Pearls]<PAOldColor> Premium Express Pack` | `[New/Returning] <PAColor0xffffff00>[Up to 3120 Pearls]<PAOldColor>Premium Express Pack` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffe9bd23>[50% Off]<PAOldColor> Character Slot Expansion Coupon` | `<PAColor0xffe9bd23>[50% Off]<PAOldColor>Character Slot Expansion Coupon` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffffff00>[1+10]<PAOldColor> Special Pearl Box` | `<PAColor0xffffff00>[1+10]<PAOldColor>Special Pearl Box` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xfffcac64>[Agent]<PAOldColor> Secret Agent's Blacksmith` | `<PAColor0xfffcac64>[Agent]<PAOldColor>Secret Agent's Blacksmith` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xfffcac64>[Agent]<PAOldColor> Agent's Supply Pack` | `<PAColor0xfffcac64>[Agent]<PAOldColor>Agent's Supply Pack` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xfffcac64>[Agent]<PAOldColor> Agent's Travel Support Pack` | `<PAColor0xfffcac64>[Agent]<PAOldColor>Agent's Travel Support Pack` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xfffcac64>[Agent]<PAOldColor> Secret Agent's Dress Code Pack` | `<PAColor0xfffcac64>[Agent]<PAOldColor>Secret Agent's Dress Code Pack` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xfffcac64>[Agent]<PAOldColor> Interdimensional Agent Pack` | `<PAColor0xfffcac64>[Agent]<PAOldColor>Interdimensional Agent Pack` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xfffcac64>[Agent]<PAOldColor> Codename: G` | `<PAColor0xfffcac64>[Agent]<PAOldColor>Codename: G` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xff00ff00>[1 Week] [Kind Gesture]<PAOldColor> Blacksmith's Favor Pack` | `[1 Week] [Kind Gesture] Blacksmith's Workshop Box x100` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffa74ac7>[Edania II]<PAOldColor> Valks' Support Pack II` | `<PAColor0xffa74ac7>[Edania II]<PAOldColor>Valks' Support Pack II` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffa74ac7>[Edania II]<PAOldColor> Valks' Support Pack I` | `<PAColor0xffa74ac7>[Edania II]<PAOldColor>Valks' Support Pack I` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffa74ac7>[65% Off] [Edania II]<PAOldColor> Specially Premium Pack` | `<PAColor0xffa74ac7>[65% Off] [Edania II]<PAOldColor>Specially Premium Pack` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xffa74ac7>[70% Off] [Edania II]<PAOldColor> Progression Support Pack` | `<PAColor0xffa74ac7>[70% Off] [Edania II]<PAOldColor>Progression Support Pack` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
| `<PAColor0xff00ff00>[1 Week] [15+15]<PAOldColor> Blacksmith's Workshop Box` | `<PAColor0xff00ff00>[1 Week] [15+15]<PAOldColor>Blacksmith's Workshop Box` | latin_target_mismatch | у полі українського відповідника стоїть інший латинський рядок | 0 |  |
