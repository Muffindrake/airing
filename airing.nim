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
    api_access: string
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
    user: string
    user_display: string
    game: string
    status: string
  configuration = object
    noise: Noise
    service_current: ptr service
    quality: seq[string]
    quality_current: string
    terminal: string
    weechat_ttv_buffer: string
    mpv_ipc_path: string

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
    url_api_base: "https://api.twitch.tv/kraken/",
    api: "",
    api_access: "",
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
    write_file fifo_path, &"{weechat_buffer_name} */join #{channel}\n"
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

proc ext_mpv_ipc(command: string, ipc_path: string) =
  discard exec_shell_cmd(&"echo '{command}' | socat - '{ipc_path}'")

proc default_user(): string =
  return get_env("AIRING_USER_TTV", "").string

proc default_terminal(): string =
  return get_env("AIRING_TERMINAL", "kitty").string

proc default_token_client(): string =
  return get_env("TWITCH_CLIENT_ID", "onsyu6idu0o41dl4ixkofx6pqq7ghn").string

proc default_token_api(): string =
  return get_env("TWITCH_ACCESS_TOKEN", "").string

proc set_prompt(s: string) =
  config.noise.set_prompt Styler.init(styleBright, s, "> ")

proc svc_ttv_cleanup() =
  svc_ttv_info_store = new_seq[svc_ttv_info](0)

proc svc_ttv_online(): Natural =
  return svc_ttv_info_store.len

proc svc_ttv_username_to_url (name: string): string =
  return "https://twitch.tv/" & name.strip.encode_url

proc svc_ttv_fetch(url: string): string =
  var res: Response
  while true:
    try:
      res = client_ttv.get(url)
    except:
      raise
    if res.code == Http429:
      const delay = 20
      echo "note: rate limited, waiting ", delay, " seconds"
      sleep delay * 1000
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
  let ret = json{"users"}{0}{"_id"}.get_str()
  if ret == "":
    raise new_exception(Exception, "no such user: " & name)
  return ret

proc svc_ttv_fetch_follows(): seq[string] =
  var url: string
  var ret: seq[string]
  var res: string
  var total: Natural = 0
  var offset: Natural = 0
  while true:
    url = &"{services[TTV].url_api_base}users/{services[TTV].user_id}/follows/channels?limit=100&offset={offset}&sortby=login&direction=asc"
    res = url.svc_ttv_fetch
    if res == "":
      raise new_exception(Exception, "invalid json")
    let json = res.parse_json
    if json{"follows"} == nil:
      raise new_exception(Exception, "invalid json")
    if total == 0:
      total = json{"_total"}.get_int
      if total == 0:
        break
    for i, e in json{"follows"}.get_elems:
      if e{"channel"}{"_id"}.get_str == "":
        raise new_exception(Exception, "invalid json")
      ret.add e{"channel"}{"_id"}.get_str
    offset += 100
    if offset > total:
      break
  return ret

proc svc_ttv_fetch_main() =
  var user_follows_ids: seq[string]
  var url: string
  var res: string
  var offset: Natural = 0
  if services[TTV].user_id == "":
    echo "error: user_id blank for ttv"
    return
  user_follows_ids = svc_ttv_fetch_follows()
  svc_ttv_cleanup()
  if user_follows_ids.len == 0:
    return
  while true:
    url = services[TTV].url_api_base & &"streams/?stream_type=live&limit=100&offset={offset}&"
    url &= "channel=" & user_follows_ids.join(sep = ",")
    res = url.svc_ttv_fetch
    let json = res.parse_json
    if json{"streams"}.get_elems.len == 0:
      break
    for i, e in json{"streams"}.get_elems:
      svc_ttv_info_store.add(svc_ttv_info (
        user: e{"channel"}{"name"}.get_str,
        user_display: e{"channel"}{"display_name"}.get_str,
        game: e{"channel"}{"game"}.get_str,
        status: e{"channel"}{"status"}.get_str.strip
      ))
      offset += 1

proc svc_ttv_update() =
  if services[TTV].user_id == "":
    services[TTV].user_id = svc_ttv_fetch_user_id_from_name(services[TTV].user_name)
  svc_ttv_fetch_main()
  svc_ttv_info_store.sort do (x, y: svc_ttv_info) -> int:
    result = cmp(x.user.to_lower, y.user.to_lower)

proc svc_ttv_get_user(index: Natural): string =
  if svc_ttv_info_store.len == 0 or index > svc_ttv_info_store.len - 1:
    raise new_exception(Exception, &"index {index} out of bounds of ttv store length {svc_ttv_info_store.len}")
  return svc_ttv_info_store[index].user

proc svc_ttv_fetch_user_info(name: string) =
  var url: string
  var res: string
  url = services[TTV].url_api_base & "users?login=" & name.encode_url
  res = url.svc_ttv_fetch
  let json = res.parse_json
  for i, e in json{"users"}{0}.get_fields:
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
    login = e.user
    disp = e.user_display
    game = e.game
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

proc only_one_argument() =
  echo "warning: command expects exactly one argument"

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

proc set_dispatch(svc: ptr service, cmd: string, args: seq[string]) =
  case cmd:
  of "q", "quality":
    if args.len != 1:
      only_one_argument()
      return
    if args[0].is_integer:
      let i = args[0].parse_int
      if i < 0 or i >= config.quality.len:
        out_of_bounds(i)
        return
      config.quality_current = config.quality[i]
    else:
      config.quality_current = args[0]
    echo "note: youtube-dl quality set: ", config.quality_current
    return
  else:
    unknown_command cmd

proc handle_input(svc: ptr service, cmd: string, args: seq[string]) =
  case cmd:
  of "b", "browse":
    if svc.username_to_url == nil or svc.online_count == nil:
      not_implemented()
      return
    for e in args:
      var url = svc.get_url_string e
      if url == "": continue
      echo "note: opening default web browser for ", url
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
      echo "note: retrieving available quality for ", url
      echo url.ext_youtubedl_quality
    return
  of "u", "user":
    svc.user_name = if args.len == 0: default_user() else: args[0]
    svc.user_id = ""
    echo "note: username set to ", svc.user_name
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
    if svc.chat_native == nil:
      not_implemented()
      return
    if args.len == 0:
      at_least_one_argument()
      return
    for e in args:
      let user = svc.get_user_string e
      if user == "": continue
      echo "note: issuing chat join command to weechat for channel ", user
      svc.chat_native(channel = user, external = config.weechat_ttv_buffer)
    return
  of "s", "set":
    if args.len == 0:
      at_least_one_argument()
      return
    svc.set_dispatch(args[0], if args.len > 1: args[1 .. ^1] else: @[])
    return
  of "ir", "ipcrun":
    if args.len == 0:
      at_least_one_argument()
      return
    for e in args:
      let url = svc.get_url_string e
      if url == "": continue
      echo "note: issuing IPC command for mpv to load ", url
      ext_mpv_ipc &"loadfile {url.quote_shell}", config.mpv_ipc_path
    return
  of "iq", "ipcquality":
    var quality: string
    if args.len == 0:
      quality = config.quality_current
    elif args.len != 1:
      only_one_argument_or_none()
      return
    else:
      quality = args[0]
    echo "note: changing youtube-dl quality setting in mpv to ", quality
    ext_mpv_ipc &"set ytdl-format \'{quality.quote_shell}\'", config.mpv_ipc_path
    return
  of "quit", "exit":
    quit QuitSuccess
  else:
    unknown_command cmd

proc init() =
  services[TTV].user_name = default_user()
  services[TTV].api = default_token_client()
  services[TTV].api_access = "Bearer " & default_token_api()
  client_ttv.headers["Accept"] = "application/vnd.twitchtv.v5+json"
  client_ttv.headers["Client-ID"] = services[TTV].api
  client_ttv.headers["Authorization"] = services[TTV].api_access
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
    "best[height<=720][tbr<=2500]",
    "best[height<=480][tbr<=2250]",
    "best[height<=360][tbr<=1750]",
    "best[height<=1440]",
    "best[height<=1080]",
    "best[height<=720]",
    "best[height<=480]",
    "best[tbr<=6000]",
    "best[tbr<=5000]",
    "best[tbr<=4000]",
    "best[tbr<=3500]",
    "best[tbr<=3250]",
    "best[tbr<=3000]",
    "best[tbr<=2500]",
    "best[tbr<=2000]",
    "best[tbr<=1500]",
    "best[tbr<=1000]",
    "best",
    "worst",
    "bestaudio",
  ]
  config.quality_current = get_env("AIRING_QUALITY", config.quality[1]).string
  config.noise = Noise.init
  if stdout.is_a_tty:
    config.service_current.ident.set_prompt
  config.terminal = default_terminal()
  config.weechat_ttv_buffer = get_env("AIRING_WEECHAT_BUFFER_TTV", "irc.server.twitch").string
  config.mpv_ipc_path = get_env("AIRING_MPV_IPC_PATH", "/tmp/mpvsocket").string

when is_main_module:
  init()
  while true:
    var line: string
    if stdout.is_a_tty:
      var ok: bool
      try:
        ok = config.noise.read_line
      except EOFError:
        break
      if not ok:
        break
      line = config.noise.get_line.strip
      if line.len != 0:
        config.noise.history_add line
      else:
        continue
    else:
      try:
        line = stdin.read_line
      except EOFError:
        break
      if line.len == 0:
        continue
    let tokens = line.parse_cmdline
    try:
      handle_input config.service_current, tokens[0], if tokens.len > 1: tokens[1 .. ^1] else: @[]
    except:
      echo get_current_exception().msg
    client_ttv.close
  client_ttv.close
