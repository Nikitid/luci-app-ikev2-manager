Demonstration statuses of the Windows window (version 7), with the data of the
layout's mock-up: everything working, one service down, no connection, reset
needed, an update ready. A debug build of the window reads one of them when
`WAYPOINT_DEMO_STATUS` names it; `WAYPOINT_DEMO_DELAY` holds each reading back
by that many milliseconds and `WAYPOINT_DEMO_FAIL=1` makes it fail.
