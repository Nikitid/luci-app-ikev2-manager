# Опись страниц LuCI

Этап 1 полировки: что реально отрисовано на шести страницах в четырёх режимах
данных и что происходит при нажатии. Снято 2026-11-01 на стенде
`scripts/luci-stand.sh` (LuCI на OpenWrt 25.12.6, язык интерфейса en-US, данные
синтетические). Страницы не менялись; разбор причин - этап 2.

## Как читать

Столбец «На стенде»:

| Значение | Смысл |
| --- | --- |
| нажат | Нажат на живой странице, результат дошёл до страницы и соответствует подписи |
| нажат: стенд | Helper вызван, но завершился ошибкой из-за стенда. Само действие **на стенде не проверяется** (нет strongSwan, nft, procd или нужных данных) |
| нажат: подмена | Как «нажат», но ответы `client-admin-show`, `-settings`, `-mail` подставлены в браузере. Остальные helper настоящие |
| вид | Только увиден на странице, не нажимался |
| не нажат | Намеренно не нажимался, причина в строке |

Helper `manager` - `/usr/libexec/ikev2-manager`, `system` -
`ikev2-manager-system`, `router` - `ikev2-domain-router`, `community` -
`ikev2-domains-community`, `admin` - `ikev2-client-admin`. Значение в скобках -
подкоманда. Вызовы из столбца «нажат» записаны из запросов страницы к `/ubus`,
остальные прочитаны в коде.

Режимы: `first-run`, `empty`, `full`, `error`. `empty+swanmon` - режим `empty`, в
котором вручную создан `/usr/sbin/swanmon`, чтобы открыть формы за заглушкой
(см. «Ограничения стенда»).

## Что видно по режимам

| Страница | first-run | empty | full | error |
| --- | --- | --- | --- | --- |
| Overview (`setup`) | Все секции. Пилюля Not configured, переключатель Managed mode и Restart policy routing отключены | Все секции. Configured | Все секции. Configured | Все секции. Not configured, таблицы зависимостей пусты, пилюля Check unavailable, Install скрыта |
| Outbound Tunnel (`client`) | Заглушка | Заглушка; с `empty+swanmon` формы, Disconnected, «Only the main tunnel is configured» | Формы, Connected, туннель Second exit | Формы, Connected, туннелей нет, блоки DNS пусты |
| Policy Routing (`routing`) | Все секции. Счётчики 0, Policy empty, нет блока источников | То же, что first-run | Заполнено, два поля туннелей | Каталог заменён сообщением The service catalog is unavailable, счётчики 0 |
| Inbound Server (`server`) | Заглушка | Заглушка; с `empty+swanmon` формы, Enabled - no certificate | Формы, Enabled - no certificate | Формы со значениями по умолчанию, Disabled, сообщения об ошибке нет |
| Users (`remote-clients`) | Форма настройки, Set up отключена, два предупреждения | Форма настройки, Set up отключена, одно предупреждение | Форма настройки, Set up включена. **Люди и сессии скрыты** | Сообщение Client configuration is unavailable, People пуст, Add person и Update service lists отключены |
| Виджет (`admin/status/overview`) | Not configured, всё Disabled | Action required, Routing stopped, Server degraded | Action required, Connected, Routing stopped, Server degraded, 0 active sessions | Строки Unavailable |

Заглушка: `Runtime dependencies are not installed`, ссылка Go to Overview. Её
показывают `client`, `server` и панель VPN-профилей, пока нет `/usr/sbin/swanmon`.

### Туннели и сессии в режиме full

- **Туннели видны.** `client`: основной Connected, карточка Second exit
  Disconnected. `routing`: поля Main tunnel (Connected) и Second exit (Not
  connected). Виджет: Connected.
- **Пользователи видны только после настройки удалённых клиентов.** Сразу в `full`
  страница Users показывает лишь форму настройки. После нажатия Set up и
  перезагрузки появляются настоящие карточки alice, bob, carol (People: 3, VPN
  profiles: 3).
- **Сессия alice видна на Users** (адрес 10.20.30.10, кнопка Disconnect): проверено
  с подменой `client-admin-*`, `users-show` и `list-sas` были настоящими.
- **В виджете сессий нет:** 0 active sessions. Виджет считает только SA с дочерней
  SA в состоянии INSTALLED, а у входящей SA на стенде `child-sas` пуст. Список
  сессий виджета не проверен.

## Overview (`setup`)

| Секция | Подпись | Тип | Что делает | Где виден | На стенде |
| --- | --- | --- | --- | --- | --- |
| Шапка | Версия, Configured / Not configured | Пилюли | `system (get)`, версия пропадает в `error` | Все | вид |
| Managed mode | Let the app manage the router | Переключатель | Часть Apply router settings | Все; отключён в `first-run`, `error` | нажат: стенд (`set-async 0 ...`, WAN 'wan' does not exist) |
| Managed mode | Details | Ссылка | На `client` | Все | вид |
| Routing control | Pause tunnel routing / Resume | Кнопка | `system (routing-pause-async / routing-resume-async)` | Все | Pause нажат; Resume не нажат |
| Routing control | Restart reliable mode | Кнопка | `system (recover-reliable-async)` | Все; отключена без Reliable mode | вид, отключена |
| Routing control | Restart policy routing | Кнопка | `system (pbr-restart-async)` | Все; отключена в `first-run`, `error` | нажат: стенд |
| Runtime dependencies | Technical details | Раскрытие | Полная таблица проверок | Все | нажат |
| Runtime dependencies | Install runtime dependencies | Кнопка, подтверждение | `system (install-deps)` | Скрыта в `error` | не нажат: подтверждение отменено, поставил бы пакеты в контейнер |
| Runtime dependencies | Reset app and remove dependencies | Кнопка, подтверждение | `system (remove-deps)` | Только при готовых зависимостях; на стенде не видна | не нажат, на стенде не проверяется |
| Runtime dependencies | Download report | Кнопка | `system (diagnostics)`, файл | Все | нажат: файл скачан |
| Network integration | WAN network | Список + поле | Часть Apply. Варианты из `ikev2-devices networks` | Все | вид: на стенде только Custom… |
| Network integration | VPN server | Флажок | Часть Apply | Нет в `first-run`, `error` | вид |
| Network integration | Custom… + поле зон | Флажок + поле | Часть Apply | Все | вид |
| Device rules | Список правил, пустое состояние No device rules | Список | `ikev2-devices dump` | Все | вид: заполненный список не виден |
| Device rules | Устройство, адрес, режим, Add | Списки, поле, кнопка | `system (device-async set-exclusions / set-included ...)` | Все | пустой адрес: Invalid address, нажат; настоящий адрес: нажат: стенд |
| DNS policy | Redirect plain DNS, Block DNS-over-TLS | Переключатели | Часть Apply | Все | нажат: стенд |
| Панель применения | Apply router settings | Кнопка | `system (set-async ...)`; серая без изменений | Все | нажат: стенд |
| Settings backup | Backup passphrase, Download backup | Поле, кнопка | `system (backup-export)`, файл | Все | нажат: без пароля ошибка, с паролем файл скачан |
| Settings backup | Backup file, Its passphrase, Import backup | Файл, поле, кнопка, подтверждение | `system (backup-import-async)` | Все | нажат: пустая форма и неверный пароль дают ошибку; верный пароль не проверялся |

## Outbound Tunnel (`client`)

Формы видны в `full`, `error`, `empty+swanmon`; в `first-run`, `empty` только заглушка.

| Секция | Подпись | Тип | Что делает | Где виден | На стенде |
| --- | --- | --- | --- | --- | --- |
| Заглушка | Go to Overview | Ссылка | На `setup` | `first-run`, `empty` | вид |
| Шапка | Gateway, Virtual IPv4, SA traffic, Tunnel traffic | Плашки | `manager (client-get)`, `swanmon list-sas` | Формы | вид: адрес шлюза пуст, фикстура его не содержит |
| Connection quality | 1 h, 6 h, 24 h | Кнопки | `ikev2-tunnel-quality (summary 6h ...)` | Формы | нажат (6 h); данных нет, Collecting data |
| Connection quality | Show all | Кнопка | Раскрывает события | Скрыта без событий | не видна |
| Speed | Tunnel service, Direct service, Direction, Streams | Списки | Параметры теста | Формы | вид; Custom file URL открывает поле, нажат |
| Speed | Test speed | Кнопка | `ikev2-tunnel-quality (speed-test-async)` | Формы | не нажат: реальный трафик; на стенде не проверяется |
| Connection | Enable client, Remote address, Remote identity, EAP username, New EAP password | Переключатель, поля | Часть Save | Формы | заполнены |
| Connection | Advanced connection settings | Кнопка-раскрытие | DPD, MTU, keepalive и Edit raw config | Формы | нажат |
| Connection | Edit raw config | Кнопка | Показывает текст профиля и предупреждение | В раскрытии | нажат |
| Connection | Reset to generated, Save custom config | Кнопки | `manager (advanced-reset-start / advanced-start)` | В режиме raw | не нажат |
| Connection | Reconnect | Кнопка | `manager (reconnect-client)` | Формы | нажат: стенд |
| Connection | Save | Кнопка | `manager (client-input)`; серая без изменений | Формы | выключение клиента: Saved, нажат; изменение адреса при включённом: нажат: стенд (нет EAP-пароля в фикстуре) |
| Connection | Save and connect | Кнопка | `manager (client-input)`, затем подключение | Формы | нажат: стенд |
| More tunnels | The main tunnel stands in for the others | Переключатель | Часть сохранения туннелей | Формы | вид |
| More tunnels | Карточка туннеля: Name, Enabled, адрес, identity, логин, пароль, DPD, MTU | Поля, списки | Часть Save tunnel | `full` | заполнены |
| More tunnels | Save tunnel | Кнопка | `manager (tunnel-input)` | `full`, новый туннель | нажат: стенд |
| More tunnels | Delete tunnel | Кнопка, подтверждение | `manager (tunnel-input)` | `full` | отмена работает; подтверждение: туннель убран, применение нажат: стенд |
| More tunnels | Add tunnel, Discard tunnel | Кнопки | Форма нового туннеля | Формы; нет в `error` | нажат |
| Tunnel DNS | Строки DoH и Bootstrap: список, поле, × | Строка | Часть Apply tunnel DNS | Формы | × нажат |
| Tunnel DNS | Add DoH server, Add bootstrap server | Кнопки | Новая строка; bootstrap отключена при шести строках | Формы | Add DoH нажат; bootstrap вид |
| Tunnel DNS | Resolve all names through the tunnel | Переключатель | `router (tunnel-resolve)` | Формы | нажат: кнопка применения включается |
| Tunnel DNS | Apply tunnel DNS | Кнопка | `manager (client-input)`; серая без изменений | Формы | нажат: стенд (нет EAP-пароля в фикстуре) |
| Router DNS upstream | DNS management | Список | Открывает остальные поля | Формы | нажат |
| Router DNS upstream | Resolve through sing-box, Browser compatibility | Переключатели | Часть Apply DNS | Отключены без Manage | вид |
| Router DNS upstream | Query strategy, Upstream protocol, строки DNS, bootstrap, fallback | Списки, поля | Часть Apply DNS | Формы | поле заполнено |
| Router DNS upstream | Add DNS server, Add bootstrap server, Add fallback server | Кнопки | Новая строка | Формы; нет в `error` | вид |
| Router DNS upstream | Apply DNS | Кнопка | `system (dns-set-async)`; серая без изменений | Формы | нажат: стенд (dnsproxy is not installed) |
| Destination DNS segments | Add DNS segment; форма Name, Domain suffixes, Discard, Save segment | Кнопки, поля | `system (dns-segment-input)` | Формы; нет в `error` | форма открыта; Save segment не нажат |

## Policy Routing (`routing`)

| Секция | Подпись | Тип | Что делает | Где виден | На стенде |
| --- | --- | --- | --- | --- | --- |
| Domain routing | Route router services by domain policy | Переключатель | `router (router-traffic)` | Все | не нажат |
| Domain routing | Logging: уровень | Раскрытие, список | `router (log-level)` | Все | нажат: Saved |
| Domain routing | Capture debug log for 60 seconds | Кнопка | `router (diagnostic-start 60)` | Отключена без FakeIP | вид, отключена |
| Domain routing | Match by name (FakeIP) | Раскрытие, кнопка | `router (activate-async)` | Все | нажат: стенд; 40 с в Enabling... с отключёнными контролами, результата нет |
| Routes | Поля туннелей и Never through the tunnel | Цели перетаскивания | Куда идёт сервис | Все | вид |
| Routes | Фишка сервиса: Where it goes, No backup, Edit, Remove | Фишка и панель | Меняют форму до Save | Все | нажат: панель открывается |
| Routes, Catalogue | Перетаскивание фишки | Жест | То же | Все | не нажат |
| Catalogue | Find a service | Поле | Фильтр | Нет в `error` | нажат |
| Catalogue | Фишка каталога | Фишка | Добавляет в выделенное поле, Save становится активной | Нет в `error` | нажат |
| Catalogue | New service; Service name, Domains, IPv4, куда, Cancel, Save service | Кнопка, форма | `community (service-schedule)` | Нет в `error` | форма открыта; Save service не нажат |
| List sources | Update lists now | Кнопка | `community (refresh-schedule force)` | Все | нажат: стенд |
| List sources | Sources for each service | Раскрытие | Источники | `full` | нажат |
| Списки | Custom domains, Custom IP, Domains never, Addresses never | Текстовые поля | Часть Save | Все | заполнены |
| Панель сохранения | Save | Кнопка | Шесть файлов, `community (schedule)`; серая без изменений | Все | неверный адрес: ошибка со строкой, нажат; настоящая пересборка нажат: стенд |

## Inbound Server (`server`)

Формы видны в `full`, `error`, `empty+swanmon`; в `first-run`, `empty` только заглушка.

| Секция | Подпись | Тип | Что делает | Где виден | На стенде |
| --- | --- | --- | --- | --- | --- |
| Заглушка | Go to Overview | Ссылка | На `setup` | `first-run`, `empty` | вид |
| Service | Enable server | Переключатель | Часть Save server | Формы | нажат: стенд (`server-input`, apply and rollback failed) |
| Service | Public identity, поле Custom… | Список, поле | Часть Save server | Формы | Custom… открывает поле, нажат |
| Service | VPN address plan, пул, шлюз, DNS | Список, поля | Часть Save server | Поля только при Custom… | нажат: стенд (нет сертификата) |
| Client routes and access | Advertised IPv4 destinations | Список, поле | Часть Save server | Формы | вид |
| Client routes and access | Allow Internet, Allow internal networks, Internal firewall zones, Allow router itself, Allow all router ports, Allowed router ports | Переключатели, флажки, поле | Часть Save server | Формы; порты отключены при all ports | вид |
| Client routes and access | Advanced access settings | Кнопка-раскрытие | Зоны ikev2in, ikev2out | Формы | нажат |
| ACME certificate | Account email, Challenge method | Поле, список | Часть Save ACME | Формы | нажат |
| ACME certificate | Advanced certificate settings; DNS-провайдер, токен, флажок | Раскрытие, поля | Часть Save ACME | Формы | нажат |
| ACME certificate | Save ACME settings | Кнопка | `manager (acme-set)`; серая без изменений | Формы | нажат: стенд |
| ACME certificate | Request certificate | Кнопка | `manager (acme-set, acme-issue)` | Формы | без адреса: ошибка, нажат; выпуск на стенде не проверяется |
| Connection behavior | MOBIKE, IKE fragmentation, XFRM MTU | Переключатели, список | Часть Save server | Формы | вид |
| Connection behavior | Advanced connection settings; таймеры, пути сертификатов | Раскрытие, списки | Часть Save server | Формы | нажат |
| Connection behavior | Edit raw config, Reset to generated, Save custom config | Кнопки | `manager (advanced-start inbound / advanced-reset-start inbound)` | В раскрытии | Edit нажат; Reset и Save не нажаты |
| Панель сохранения | Save server | Кнопка | `manager (server-input)`; серая без изменений | Формы | нажат: стенд |

## Users (`remote-clients`)

Секции People и дальше появляются только при `initialized=true`. На стенде это
состояние получается нажатием Set up. Контролы карточек сняты с подменой
`client-admin-*`: двое с Waypoint, свободное место, опубликованный сервис.

| Секция | Подпись | Тип | Что делает | Где виден | На стенде |
| --- | --- | --- | --- | --- | --- |
| Set up remote clients | Accept remote clients, Registration port, Exit tunnel, Virtual subnet | Переключатель, поля, список | Часть Set up | Нет настройки | заполнены |
| Set up remote clients | Set up remote clients | Кнопка | `admin (client-admin-setup)` | Отключена без сервера и туннеля (`first-run`, `empty`) | нажат: стенд; сообщение об ошибке, но настройка сохранилась |
| People | Windows application | Кнопка | Скачивает установщик | После настройки, `error` | нажат: подмена, файл скачан |
| People | Add person; Who uses it, E-mail, Note, Kind of device, Devices, Link is valid for, сервисы, Create invitation | Диалог | `admin (client-admin-invite)` | После настройки; отключена в `error` | диалог открыт, подмена; Create invitation не нажат |
| People | Search | Поле | Фильтр карточек | После настройки | нажат: подмена |
| People | Disconnect all (значок) | Кнопка, подтверждение | `manager (disconnect-all)` | После настройки | отмена, подмена |
| People | Active links: Show, New link, Revoke | Кнопки | `admin (client-admin-link)`, диалог, `close-places` | Есть ссылки | Show и New link нажаты, подмена; Revoke не нажат |
| Карточка человека | Раскрытие карточки | Кнопка | Показывает устройства и профили | Есть люди | нажат |
| Карточка человека | Waypoint link | Диалог | `admin (client-admin-invite)` | Есть люди | диалог открыт, подмена |
| Карточка человека | Add an ordinary VPN profile; Username, Password, политика, Save | Диалог | `manager (user-secret-set)`, `admin (assign-profiles)` | Есть люди | диалог открыт; Save не нажат |
| Карточка человека | Edit; Who uses it, профили, Save | Диалог | `admin (client-admin-update)` | Есть люди | диалог открыт, подмена |
| Устройство Waypoint | Switch access on / Approve | Кнопка | `admin (client-admin-update)` | Доступ выключен | нажат: подмена, запись отклонена (нет настоящего состояния) |
| Устройство Waypoint | Device: name and services; Diagnostics..., Rights... | Диалог | `client-admin-update`, `client-admin-report` | Есть устройства | диалог открыт, подмена; Diagnostics не нажат |
| Устройство Waypoint | Remove; свободное место Remove | Кнопка, диалог | `client-admin-update` | Есть устройства | диалог открыт, подмена; подтверждение не нажато |
| VPN-профиль | Disconnect | Кнопка без подтверждения | `manager (disconnect <id>)` | Есть сессия | вызов записан; разрыв на стенде не проверяется |
| VPN-профиль | Give the profile: iOS, Windows, Android, QR code | Кнопки | `manager (profile-export / profile-link)` | Есть профили | панель открыта, скачивание не нажато |
| VPN-профиль | Access policy | Диалог | `manager (user-secret-set)` | Есть профили | диалог открыт; Save не нажат |
| VPN-профиль | Change password | Диалог | `manager (user-secret-set)` | Есть профили | диалог открыт; Save не нажат |
| VPN-профиль | Delete | Кнопка, подтверждение | `manager (user-delete)` | Есть профили | отмена работает |
| Services for Waypoint | Update service lists | Кнопка | `admin (client-admin-refresh)` | После настройки; отключена в `error` | нажат: подмена, Service lists updated |
| Services for Waypoint | Service to publish, Publish | Список, кнопка | `admin (client-admin-update)` | После настройки | нажат: подмена, запись отклонена |
| Services for Waypoint | Who has this service, Ports, Withdraw | Диалоги | `client-admin-update` | Есть сервисы | диалоги открыты, подмена; Save и Withdraw не нажаты |
| Settings | Accept, Approve by hand, порт, туннель, подсеть, Save | Раскрытие, форма | `admin (client-admin-setup)` | После настройки | раскрыто, подмена; Save не нажат |
| Mail for invitation links | Сервис, SMTP, порт, шифрование, логин, пароль, отправитель, получатель, Send test, Save | Раскрытие, форма | `client-admin-mail-save / -send` | После настройки | раскрыто, подмена; почта на стенде не проверяется |
| Journal | События | Раскрытие | `client-admin-show` | После настройки | раскрыто, подмена |
| Inbound connection diagnostics | Capture for 60 seconds | Раскрытие, кнопка | `manager (diagnostic-start 60)` | Все, кроме заглушки панели | нажат: стенд |

## Виджет (`admin/status/overview`)

| Секция | Подпись | Тип | Что делает | Где виден | На стенде |
| --- | --- | --- | --- | --- | --- |
| IKEv2 Manager | Project status, Outbound tunnel, Policy routing, Inbound server | Строки состояния | `manager (widget-status)`, `swanmon list-sas` | Все | вид во всех режимах |
| IKEv2 Manager | Список сессий | Таблица | Только при SA с INSTALLED | Нет ни в одном режиме | не проверено |
| IKEv2 Manager | Open IKEv2 Manager | Ссылка | На `setup` | Все | вид |
| IKEv2 Manager | HIDE | Кнопка LuCI | Сворачивает блок | Все | вид, контрол LuCI |

## Итог после исправлений

Этап 5, 2026-11-02: `probe` по пяти режимам (`first-run`, `empty`, `vpn-only`, `full`,
`error`), шесть страниц, обе темы, 1440 и 390 px: **ERROR нет**. Остались WARN: `target`
на `routing` и `center` на `remote-clients` и у кнопки HIDE в LuCI. `scripts/ci-check.sh`
проходит. Снимки: `build/luci-stand/final-<режим>/`. Таблицы ниже описывают этап 1. На
странице статуса `probe` идёт без `timing`: её загрузкой управляет LuCI. Диалоги `probe`
не открывает.

После этапа 5, по замечаниям с роутера:

- Вкладка дополнительного туннеля рисовала график на тёмной подложке и без заливки под
  линией. Обёртка графика получала атрибут `style` при скрытии и показе, а тема LuCI
  красит `#view div[style] > svg`; градиент с общим `id` брался из скрытой вкладки
  основного туннеля. Теперь график скрывается через `hidden`, у каждого свой градиент.
  Стенд засевает историю и для второго туннеля (`samples-2`), иначе вкладка показывала
  только «Collecting data» и дефект не был виден.
- Иконки профилей у пользователей: Android был сжатым прямоугольником, QR из залитых
  квадратов, ключ читался как лупа. Перерисованы в той же сетке 24 и толщине линии,
  что остальные. Разделитель группы профилей стал таким же коротким, как остальные
  разделители в ряду кнопок.
- Блок настроек дополнительного туннеля назывался именем туннеля (оно уже на вкладке)
  и держал пустую строку состояния. Теперь он «Connection» с тем же пояснением, что у
  основного; строка с адресом появляется, только когда есть что показать.
- Тема bootstrap рисовала при наведении на кнопку и фокусе поля свою голубую рамку
  (`!important` от `--focus-color-rgb`) и голубое свечение, на всех страницах. Внутри
  `.ikev2-page` эта переменная теперь указывает на акцент; поле с ошибкой остаётся
  красным.

Обход 2026-11-07, после переделки туннелей (Save отдельно от Connect и Disconnect) и
двух колонок на `routing` (каталог сбоку); снимки `build/luci-stand/fix3-<режим>/`:

- `setup`, 390 px: на телефоне `mobile.css` темы ставит полям 16 px, чтобы iOS не
  увеличивала страницу, и поле становится 39,6 px, а кнопка рядом оставалась 36.
  Кнопки, квадратные кнопки удаления и список туннеля у устройства теперь той же высоты.
  `probe` давал `siblings` до правки и молчит после.
- `setup`, 390 px: в карточке устройства без туннеля подпись флажка шла под флажком, а
  сам флажок выходил за отступ карточки: подпись не помещалась в квадрат 2rem. Теперь
  флажок и подпись в строку. `probe` этого не видит, найдено по снимку.
- `ci-check` проходит; `probe` по пяти режимам без ERROR (снимки
  `build/luci-stand/final2-<режим>/`). Фишки каталога и вкладка на `routing` под липкой
  панелью Save теперь INFO `overlap`: `probe` отличает плавающий слой (`fixed`, `sticky`)
  от наложения в потоке. Прокрутка до конца показывает, что под панелью ничего не
  остаётся, каталог прокручивается сам.
- Открыто: на телефоне у включённого устройства после «Exclusions go direct» стоит
  название столбца «Routing».
- Кнопки второго туннеля на стенде: Save сохраняет имя и не трогает `enabled`;
  Disconnect ставит `enabled=0`, Connect - `enabled=1`. Без strongSwan в контейнере оба
  заканчиваются ошибкой, как и должны; итог раньше говорил «Tunnel settings were saved,
  but applying them failed», хотя ничего не сохранялось. Теперь «The tunnel could not be
  stopped cleanly…» и «Tunnel did not come up…»; тест `scripts/test-tunnel-manager.sh`
  ждёт окончания задания и падал на старых текстах. Стенд засевает пароль второго
  туннеля: без него Save отказывал «EAP password is required for a new tunnel».
- Выключенный кнопкой Disconnect туннель продолжает отклонять то, что привязано к нему
  без резерва, по IPv4 и IPv6 (`scripts/openwrt/scenarios.sh`, OpenWrt 24.10.8 и
  25.12.6); с выходами только по включённым туннелям сценарий падает, трафик уходит в WAN.
- Открыто: на первом туннеле кнопка «Save», на остальных «Save tunnel».

## Сводка probe

`IKEV2_STAND_LABEL=<режим> scripts/luci-stand.sh probe` без аргументов, по чистому
стенду, 1440 и 390 px, обе темы, задержка данных 1500 мс. Обход дошёл до всех шести
страниц в каждом режиме (24 отчёта). Ячейка: ERROR / WARN.

| Страница | first-run | empty | full | error |
| --- | --- | --- | --- | --- |
| setup | 20 / 0 | 20 / 0 | 20 / 0 | 18 / 0 |
| client | 17 / 0 | 17 / 0 | 17 / 0 | 17 / 0 |
| routing | 8 / 4 | 17 / 4 | 18 / 4 | 17 / 4 |
| server | 17 / 0 | 17 / 0 | 17 / 0 | 17 / 0 |
| remote-clients | 17 / 0 | 17 / 0 | 17 / 0 | 18 / 1 |
| overview | 12 / 5 | 12 / 5 | 12 / 5 | 12 / 5 |
| Итого | 91 / 9 | 100 / 9 | 101 / 9 | 99 / 10 |

Виды:

| Вид | Уровень | Где | Сколько | Что сказано |
| --- | --- | --- | --- | --- |
| `timing` | ERROR | Все | 12 на страницу, в `first-run` routing 3 | Положение зависит от скорости данных, элемент пропал с задержкой. Проба выводит не больше 10 строк на группу, так что это не число проблем |
| `focus` | ERROR | Все, кроме overview | 5 на страницу | Вкладки LuCI `#tabmenu` не меняются при фокусе. Других элементов нет |
| `overflow` | ERROR | setup, кроме `error` | 2 | На 390 px страница шире окна: 672 px, пилюля версии strongSwan выходит на 282 px |
| `siblings` | ERROR | setup, везде; routing, `full` | 1 | Соседние контролы 36 и 37,6 px: форма Device rules, New service рядом с полем поиска |
| `center` | ERROR | remote-clients, `error` | 1 | Значок Disconnect all смещён на 4,1 px |
| `center` | WARN | overview; remote-clients, `error` | 5; 1 | HIDE в LuCI 1 px; значок Windows application 1,3 px |
| `target` | WARN | routing | 4 | Заголовки раскрытий Logging и How selected... высотой 18 px |

## Замечания для этапа 2

Наблюдения, причины не разбирались.

1. Роутер с VPN-пользователями, но без настройки удалённых клиентов, не показывает
   ни людей, ни сессий: `managed` скрыт при `initialized=false`.
2. Set up remote clients пишет об ошибке, но `initialized=true` и подсеть
   («Fixed once set») уже сохранены. Страница остаётся на форме до перезагрузки.
3. В `error` `server` показывает форму со значениями по умолчанию и пилюлю Disabled,
   а `setup` - Not configured, `routing` - Policy empty. Сбой чтения выглядит как
   пустая настройка, Save мог бы её записать.
4. На одних данных `setup` показывает Routing active, а виджет - Routing stopped.
   Routing active есть и в `first-run`.
5. В `full` переключатель Managed mode включён при тексте «сначала установите
   зависимости».
6. Users считает alice в сети, виджет - 0 active sessions. Возможно, дело в фикстуре
   SA: проверить с дочерней SA.
7. Список Service to publish на настоящих данных показывает идентификаторы
   (`anthropic_ai`), `routing` - названия (Anthropic).
8. Save ACME settings выводит сырой текст `/sbin/uci: Entry not found`.
9. Disconnect одного профиля без подтверждения, Disconnect all и Delete - с ним.
10. Match by name остаётся в Enabling... дольше 40 с, контролы отключены: стенд или страница.
11. Download report занимает больше 6 с и меньше 40 с, с подписью Collecting...

## Ограничения стенда

Уточнено на этапе 2: `empty` создаёт `swanmon`, `error` ломает и его, `mode` сбрасывает
удалённых клиентов, почту и качество. Появился режим `vpn-only`: пользователи и туннели
без настройки удалённых клиентов. `lang ru` включает русский каталог. В фикстурах есть
EAP-пароль основного туннеля, адрес шлюза, дочерняя SA, сети `lan` и `wan`, соседи, правила
устройств, DNS-сегмент, сутки Connection quality, привязка сервиса к туннелю, двое на
Waypoint и почта. Таблицы выше сняты на этапе 1, поэтому строки «заглушка» для `empty`,
«нажат: подмена» и «нет EAP-пароля» теперь устарели; находки - в `docs/qa/AUDIT.md`.

- Нет strongSwan, nft, procd: Reconnect, применение туннелей, сервера, маршрутизации
  и DNS, Capture, Update lists завершаются ошибкой. Это не проверка действий.
- Нет `msmtp`: почта видна, Send test и отправка ссылки не проверяются.
- Нет пакета acme: Save ACME settings падает, выпуск сертификата не проверяется.
- Устройства Waypoint записаны прямо в хранилище, без регистрации. Отчётов диагностики и
  ожидающих ссылок в фикстуре нет.
- EAP-пароля второго туннеля нет: его сохранение без нового пароля не проверялось.
- `delay` округляется вверх до целых секунд: BusyBox `sleep` не принимает дробные.
- В `probe` проверка `timing` даёт шум, см. F-01 в `docs/qa/AUDIT.md`.

## Не проверено

Подробно - `docs/qa/AUDIT.md`, раздел «Не проверено». Из описи этапа 1 остаётся:

- Состояния Paused и Reliable mode, ожидающие ссылки.
- Не нажимались: Install и Reset, Resume, Test speed, Save custom config и Reset to
  generated, импорт с верным паролем, Create invitation, Save в диалогах Users, Send
  test, перетаскивание фишек, скачивание профилей и QR.
- Скринридер. Обход клавиатурой выборочный: сценарии записаны в AUDIT, раздел 5.
