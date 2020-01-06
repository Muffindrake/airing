import strutils
import uri
import tables
import os
import httpclient
from unicode import validate_utf8
import json
import strformat
import algorithm
import browsers
import system
import osproc
import terminal

import noise

type
        service = tuple
                name: string
                name_short: string
                ident: string
                url_api_base: string
                api: string
                user_name: string
                user_id: string
                username_to_url: proc (name: string): string {.nimcall.}
                update: proc () {.nimcall.}
                get_user: proc (index: Natural): string {.nimcall.}
                listing: proc () {.nimcall.}
                info: proc (name: string) {.nimcall.}
                cleanup: proc () {.nimcall.}
                online_count: proc (): Natural {.nimcall.}
                web_popout: proc (name: string) {.nimcall.}
                chat_web: proc (name: string) {.nimcall.}
                chat_native: proc (channel, external: string) {.nimcall.}
        service_ident = enum
                TTV = 0
                SVC_N
        svc_ttv_info = tuple
                user_id: string
                game_id: string
                status: string
        configuration = object
                noise: Noise
                service_current: ptr service
                quality: seq[string]
                quality_current: string
                terminal: string
                weechat_ttv_buffer: string

var svc_ttv_info_store: seq[svc_ttv_info]
var map_svc_ttv_gameid_to_name = init_table[string, string]()
var map_svc_ttv_userid_to_login_display = init_table[string, (string, string)]()
var client_ttv = new_http_client()
var config: configuration

var services = [
        TTV: service (
                name: "Twitch.tv",
                name_short: "TTV",
                ident: "twitch",
                url_api_base: "https://api.twitch.tv/helix/",
                api: "onsyu6idu0o41dl4ixkofx6pqq7ghn",
                user_name: "",
                user_id: "",
                username_to_url: nil,
                update: nil,
                get_user: nil,
                listing: nil,
                info: nil,
                cleanup: nil,
                online_count: nil,
                web_popout: nil,
                chat_web: nil,
                chat_native: nil,
        )
]

proc is_integer(s: string): bool =
        for e in s:
                if not e.is_digit: return false
        return true

# gives a range of a container divided into page_number pages of page_size size
proc chunks(page_size, page_number, page_index, container_length: Natural): HSlice[0,system.int.high] =
        if page_number == 0:
                raise new_exception(Exception, "chunks called with page_number == 0")
        if page_index == page_number - 1:
                return page_index * page_size ..< int(container_length)
        else:
                return page_index * page_size ..< (page_index + 1) * page_size

# same as the previous, except yields one less element per page
proc chunks_join(page_size, page_number, page_index, container_length: Natural): HSlice[0,system.int.high] =
        if page_number == 0:
                raise new_exception(Exception, "chunks_join called with page_number == 0")
        if page_index == page_number - 1:
                return page_index * page_size ..< int(container_length) - 1
        else:
                return page_index * page_size ..< (page_index + 1) * page_size - 1

proc page_count(page_size, container_length: Natural): Natural =
        return container_length div page_size + (if container_length mod page_size > 0: 1 else: 0)

proc ext_weechat_irc_join(weechat_buffer_name, channel: string) =
        let fifo_path = get_env("WEECHAT_HOME", "~/.weechat".expand_tilde) & "/weechat_fifo"
        try:
                write_file(fifo_path, &"{weechat_buffer_name} */join #{channel}\n")
        except:
                raise

proc ext_session_is_graphical(): bool =
        return exists_env("DISPLAY")

proc ext_video_player(terminal = "xterm", url, quality: string) =
        if ext_session_is_graphical():
                discard exec_shell_cmd(&"""nohup {terminal} -e mpv "{url}" --ytdl-format='{quality}' >/dev/null 2>&1 &""")
        else:
                discard exec_shell_cmd(&"""mpv "{url}" --ytdl-format='{quality}'""")

proc ext_youtubedl_quality(url: string): string =
        let res = exec_cmd_ex("youtube-dl --socket-timeout 20 -F " & url & " 2>/dev/null | sed -e '/^\\[.*/d' -e '/^format code.*/d' -e '/^ERROR.*/d' | awk '{print $3, $4, $1}'")
        return res.output.string

proc default_user(): string =
        return get_env("USER", "muffindrake").string

proc default_terminal(): string=
        return "urxvt"

proc set_prompt(s: string) =
        config.noise.set_prompt Styler.init(styleBright, s, "> ")

proc svc_ttv_cleanup() =
        svc_ttv_info_store = new_seq[svc_ttv_info](0)

proc svc_ttv_online(): Natural =
        return svc_ttv_info_store.len

proc svc_ttv_username_to_url (name: string): string =
        return "https://twitch.tv/" & name.strip.encode_url

proc svc_ttv_check_game_ids(): seq[string] =
        var ret: seq[string]
        for i, e in svc_ttv_info_store:
                if not map_svc_ttv_gameid_to_name.has_key(e.game_id):
                        ret.add(e.game_id)
        return ret

proc svc_ttv_fetch(url: string): string =
        var res: Response
        while true:
                try:
                        res = client_ttv.get(url)
                except:
                        raise
                if res.code == Http429:
                        const delay = 20;
                        echo "note: rate limited, waiting ", delay, " seconds"
                        sleep(delay * 1000)
                        continue
                break
        if res.body.validate_utf8 != -1:
                return ""
        return res.body

proc svc_ttv_fetch_user_id_from_name(name: string): string =
        let res = svc_ttv_fetch(
                services[TTV].url_api_base & "users?login=" & name)
        if res == "":
                raise new_exception(Exception, "no such user: " & name)
        let json = try: res.parse_json except: raise
        let ret = json{"data"}{0}{"id"}.get_str()
        if ret == "":
                raise new_exception(Exception, "no such user: " & name)
        return ret

proc svc_ttv_fetch_follows(): seq[string] =
        var page_token: string
        var url: string
        var ret: seq[string]
        var res: string
        while true:
                url = &"{services[TTV].url_api_base}users/follows?first=100&from_id={services[TTV].user_id}"
                url = url & (if page_token == "": "" else: "&after=" & page_token)
                res = url.svc_ttv_fetch
                if res == "":
                        raise new_exception(Exception, "invalid json")
                let json = res.parse_json
                if json{"data"} == nil:
                        raise new_exception(Exception, "invalid json")
                for i, e in json{"data"}.get_elems:
                        if e{"to_id"}.get_str == "":
                                raise new_exception(Exception, "invalid json")
                        ret.add(e{"to_id"}.get_str)
                page_token = json{"pagination"}{"cursor"}.get_str
                if page_token == "":
                        break
        return ret

proc svc_ttv_fetch_main() =
        var user_follows_ids: seq[string]
        var page_index: Natural
        var pages: Natural
        const page_size = 100
        var url: string
        var res: string
        if services[TTV].user_id == "":
                echo "error: user_id blank for ttv"
                return
        user_follows_ids = svc_ttv_fetch_follows()
        svc_ttv_cleanup()
        if user_follows_ids.len == 0:
                return
        pages = page_count(page_size, user_follows_ids.len)
        while page_index < pages:
                url = services[TTV].url_api_base & "streams?first=" & $page_size & "&"
                url &= "user_id=" & user_follows_ids[chunks(page_size, pages, page_index, user_follows_ids.len)].join(sep = "&user_id=")
                res = url.svc_ttv_fetch
                let json = res.parse_json
                for i, e in json{"data"}.get_elems:
                        svc_ttv_info_store.add(svc_ttv_info (
                                user_id: e{"user_id"}.get_str,
                                game_id: e{"game_id"}.get_str,
                                status: e{"title"}.get_str.strip
                        ))
                page_index += 1

proc svc_ttv_fetch_game_by_ids() =
        var url: string
        var page_index: Natural
        var pages: Natural
        const page_size = 100
        var res: string
        var game_ids: seq[string]
        game_ids = svc_ttv_check_game_ids()
        if game_ids.len == 0:
                return
        pages = page_count(page_size, game_ids.len)
        while page_index < pages:
                url = services[TTV].url_api_base & "games?"
                url &= "id=" & game_ids[chunks(page_size, pages, page_index, game_ids.len)].join(sep = "&id=")
                res = url.svc_ttv_fetch
                let json = res.parse_json
                for i, e in json{"data"}.get_elems:
                        map_svc_ttv_gameid_to_name[e{"id"}.get_str] = e{"name"}.get_str
                page_index += 1

proc svc_ttv_fetch_user_login_display() =
        var url: string
        var res: string
        var page_index: Natural
        var pages: Natural
        const page_size = 100
        if svc_ttv_info_store.len == 0:
                return
        pages = page_count(page_size, svc_ttv_info_store.len)
        while page_index < pages:
                url = services[TTV].url_api_base & "users?id="
                for i, e in svc_ttv_info_store[chunks_join(page_size, pages, page_index, svc_ttv_info_store.len)]:
                        url &= e.user_id & "&id="
                url &= svc_ttv_info_store[if page_index == pages - 1: svc_ttv_info_store.len - 1 else: (page_index + 1) * page_size - 1].user_id
                res = url.svc_ttv_fetch
                let json = res.parse_json
                for i, e in json{"data"}.get_elems:
                        map_svc_ttv_userid_to_login_display[e{"id"}.get_str] = (e{"login"}.get_str, e{"display_name"}.get_str)
                page_index += 1

proc svc_ttv_update() =
        if services[TTV].user_id == "":
                services[TTV].user_id = svc_ttv_fetch_user_id_from_name(services[TTV].user_name)
        svc_ttv_fetch_main()
        svc_ttv_fetch_game_by_ids()
        svc_ttv_fetch_user_login_display()
        svc_ttv_info_store.sort do (x, y: svc_ttv_info) -> int:
                result = cmp(map_svc_ttv_userid_to_login_display[x.user_id][0].to_lower, map_svc_ttv_userid_to_login_display[y.user_id][0].to_lower)

proc svc_ttv_get_user(index: Natural): string =
        if svc_ttv_info_store.len == 0 or index > svc_ttv_info_store.len - 1:
                raise new_exception(Exception, &"index {index} out of bounds of ttv store length {svc_ttv_info_store.len}")
        if not map_svc_ttv_userid_to_login_display.has_key(svc_ttv_info_store[index].user_id):
                raise new_exception(Exception, &"user_id {svc_ttv_info_store[index].user_id} not in map")
        return map_svc_ttv_userid_to_login_display[svc_ttv_info_store[index].user_id][0]

proc svc_ttv_fetch_user_info(name: string) =
        var url: string
        var res: string
        url = services[TTV].url_api_base & "users?login=" & name.encode_url
        res = url.svc_ttv_fetch
        let json = res.parse_json
        for i, e in json{"data"}{0}.get_fields:
                echo i, ": ", $e

proc svc_ttv_web_popout(name: string) =
        open_default_browser(&"https://player.twitch.tv/?channel={name.encode_url}")

proc svc_ttv_web_chat(name: string) =
        open_default_browser(&"https://www.twitch.tv/popout/{name.encode_url}/chat?popout=")

proc svc_ttv_listing() =
        if svc_ttv_info_store.len == 0:
                echo "there is no online information to list"
                return
        var login: string
        var disp: string
        var game: string
        for i, e in svc_ttv_info_store:
                if map_svc_ttv_userid_to_login_display.has_key e.user_id:
                        login = map_svc_ttv_userid_to_login_display[e.user_id][0]
                        if login == "":
                                login = "n/a"
                        disp = map_svc_ttv_userid_to_login_display[e.user_id][1]
                        if disp == "":
                                disp = "n/a"
                else:
                        login = "n/a"
                        disp = "n/a"
                if map_svc_ttv_gameid_to_name.has_key(e.game_id):
                        game = map_svc_ttv_gameid_to_name[e.game_id]
                else:
                        game = "n/a"
                if cmp_ignore_case(login, disp) != 0:
                        disp = &"{disp}({login})"
                if stdout.is_a_tty:
                        styled_echo styleUnderscore, &"{i:02}", resetStyle, " ", disp, " <", styleBright, game, resetStyle, "> ", e.status
                else:
                        echo &"{i:02} ", disp, " <", game, "> ", e.status

proc svc_ttv_chat_native(channel, external: string) =
        ext_weechat_irc_join(channel = channel, weechat_buffer_name = external)

proc out_of_bounds(i: int) =
        echo "error: index ", i, " out of bounds"

proc not_implemented() =
        echo "error: not implemented"

proc no_arguments() =
        echo "warning: command expects no arguments"

proc only_one_argument_or_none() =
        echo "warning: command expects one or no arguments"

proc unknown_command(name: string) =
        echo "error: unknown command ", name

proc at_least_one_argument() =
        echo "error: command expects at least one argument"

# implies online_count proc pointer != nil
proc get_url_string(svc: ptr service, arg: string): string =
        var i: int
        if arg.is_integer:
                i = arg.parse_int
                if i < svc.online_count():
                        return svc.username_to_url(svc.get_user(i))
                else:
                        out_of_bounds i
                        return ""
        return svc.username_to_url(arg)

proc get_user_string(svc: ptr service, arg: string): string =
        var i: int
        if arg.is_integer:
                i = arg.parse_int
                if i < svc.online_count():
                        return svc.get_user i
                else:
                        out_of_bounds i
                        return ""
        return arg

proc list_dispatch(svc: ptr service, cmd: string, args: seq[string]) =
        case cmd:
        of "c", "config":
                not_implemented()
                return
        of "q", "quality":
                for i, e in config.quality:
                        styled_echo styleUnderscore, $i, resetStyle, "\t", e
                return
        else:
                unknown_command(cmd)

proc handle_input(svc: ptr service, cmd: string, args: seq[string]) =
        case cmd:
        of "b", "browse":
                if svc.username_to_url == nil or svc.online_count == nil:
                        not_implemented()
                        return
                for e in args:
                        var url = svc.get_url_string e
                        if url == "": continue
                        echo "opening default web browser for ", url
                        open_default_browser url
                return
        of "f", "fetch":
                if svc.update == nil:
                        not_implemented()
                        return
                svc.update()
                echo "note: successfully fetched service information"
                if args.len != 0:
                        no_arguments()
                return
        of "q", "quality":
                if svc.username_to_url == nil or svc.online_count == nil:
                        not_implemented()
                        return
                for e in args:
                        let url = svc.get_url_string e
                        if url == "": continue
                        echo "retrieving available quality for ", url
                        echo url.ext_youtubedl_quality
                return
        of "u", "user":
                svc.user_name = if args.len == 0: default_user() else: args[0]
                svc.user_id = ""
                echo "username set to ", svc.user_name
                if args.len > 1:
                        only_one_argument_or_none()
                return
        of "i", "info":
                if svc.online_count == nil or svc.info == nil:
                        not_implemented()
                        return
                for e in args:
                        let user = svc.get_user_string e
                        if user == "": continue
                        echo "note: retrieving channel information for ", user
                        svc.info user
                return
        of "l", "list":
                if args.len == 0:
                        if svc.listing == nil:
                                not_implemented()
                                return
                        svc.listing()
                        return
                svc.list_dispatch(args[0], if args.len > 1: args[1 .. ^1] else: @[])
                return
        of "g", "get":
                if svc.update == nil or svc.online_count == nil or svc.listing == nil:
                        not_implemented()
                        return
                svc.update()
                echo "note: successfully fetched service information, ", svc.online_count(), " online"
                svc.listing()
                if args.len != 0:
                        no_arguments()
                return
        of "r", "run":
                if args.len == 0:
                        at_least_one_argument()
                        return
                for e in args:
                        let url = svc.get_url_string e
                        if url == "": continue
                        echo "note: running external player for ", url
                        ext_video_player(terminal = config.terminal, url = url, quality = config.quality_current)
                return
        of "c", "chat":
                if args.len == 0:
                        at_least_one_argument()
                        return
                for e in args:
                        let user = svc.get_user_string e
                        if user == "": continue
                        echo "note: issuing chat join command to weechat for channel ", user
                        svc.chat_native(channel = user, external = config.weechat_ttv_buffer)
                return
        of "quit", "exit":
                quit(QuitSuccess)
        else:
                unknown_command(cmd)

proc init() =
        services[TTV].user_name = default_user()
        client_ttv.headers["Client-ID"] = services[TTV].api
        services[TTV].update = svc_ttv_update
        services[TTV].username_to_url = svc_ttv_username_to_url
        services[TTV].get_user = svc_ttv_get_user
        services[TTV].info = svc_ttv_fetch_user_info
        services[TTV].cleanup = svc_ttv_cleanup
        services[TTV].online_count = svc_ttv_online
        services[TTV].web_popout = svc_ttv_web_popout
        services[TTV].chat_web = svc_ttv_web_chat
        services[TTV].chat_native = svc_ttv_chat_native
        services[TTV].listing = svc_ttv_listing
        config.service_current = addr services[TTV]
        config.quality.add [
                "best[height <=? 720][tbr <=? 2500]",
                "best[height <=? 480][tbr <=? 2250]",
                "best[height <=? 360][tbr <=? 1750]",
                "best[height <=? 1440]",
                "best[height <=? 1080]",
                "best[height <=? 720]",
                "best[height <=? 480]",
                "best[tbr <=? 6000]",
                "best[tbr <=? 5000]",
                "best[tbr <=? 4000]",
                "best[tbr <=? 3500]",
                "best[tbr <=? 3250]",
                "best[tbr <=? 3000]",
                "best[tbr <=? 2500]",
                "best[tbr <=? 2000]",
                "best[tbr <=? 1500]",
                "best[tbr <=? 1000]",
                "best",
                "worst",
                "bestaudio",
        ]
        config.quality_current = config.quality[1]
        config.noise = Noise.init
        config.service_current.ident.set_prompt
        config.terminal = default_terminal()
        config.weechat_ttv_buffer = "irc.server.twitch"

when is_main_module:
        init()
        while true:
                let ok = config.noise.read_line
                if not ok: break
                let line = config.noise.get_line.strip
                if line.len != 0:
                        config.noise.history_add line
                else:
                        continue
                let tokens = line.parse_cmdline
                try:
                        handle_input config.service_current, tokens[0], if tokens.len > 1: tokens[1 .. ^1] else: @[]
                except:
                        echo get_current_exception().msg
        client_ttv.close
