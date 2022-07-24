# airing
A command line interface to live stream services

Currently defunct, due to numerous Twitch API changes which are extremely hostile towards this type of application.

```
twitch> u qttsix
username set to qttsix
twitch> g
note: successfully fetched service information, 36 online
00 小夜夜(albislol) <Age of Empires II: Definitive Edition> 【ahq Albis】1/6 早睡早起 <SMOrc>
01 逼比(bebelolz) <League of Legends> [JT BeBe]  1/6 重返艾歐尼亞
02 大曲(darch0431) <Path of Exile> 【大曲】1/6 最後五天
03 EJAMI <Art> 【EJAMI】繪圖實況中
04 ESAMarathon <Xenoblade Chronicles X> #ESASummer18 - Xenoblade Chronicles X [Any% (Offline)] by legrandgrand
05 ESL_SC2 <StarCraft II> RERUN: Harstem [P] vs. Trap [P] - UB Ro4 - B4 - IEM Katowice 2018
06 懶貓(failverde) <Just Chatting> 【懶貓】掛軸開賣辣 !掛軸 立牌能填寫囉 !立牌 !懶貓子 !Discord
07 九櫻(gallant99770) <Art> 繼續趕工....
08 GamesDoneQuick <Myst III: Exile> AGDQ 2020 benefiting the Prevent Cancer Foundation - Myst III: Exile
09 고스트(ghostgc) <DJMAX Respect> 리듬게임 ㅋ
10 龜狗(gueigotv) <Path of Exile> 🐢龜狗🐢【1/6】破產的賺錢機器 開刷
11 給瑞(j30915gary) <Assassin's Creed III> 【PC Assassin's Creed III】繼續偷看祖先(X
12 japanese_restream <Myst III: Exile> [JPN] AGDQ 2020: Myst III: Exile
[...]
```
The `g` command fetches online information of the current set user (which is highly platform dependent, but on twitch.tv your following list is public anyway), and then lists the most relevant information such as who is currently streaming, their current game and their stream status text.

Other commands include (`var` refers to a variable amount of arguments that can be indices, context-dependent, or arguments delimited by whitespace or quotes "", while `arg` is a single argument):

- b `var` : open the default web browser to visit the channel's web page
- f : download online information about the currently set user
- q `var` : using youtube-dl, list available formats for a given or more streams
- u `arg` : set current user
- i `var` : dump detailed channel information
- l : list current online information
- l q : list compiled-in stream quality selections to be selected before passed to youtube-dl
- l c : list configuration options
- g : download online information about currently set user, and then list all online channels with name, game and status
- r `var` : run given channel stream in external video player
- c `var` : run given channel chat in external chat program (currently weechat)
- s q `arg` : set quality string to be passed into youtube-dl
- iq : set mpv's `ytdl-format` value through IPC to what is currently set as quality in airing
- iq `arg` : set mpv's `ytdl-format` value through IPC to `arg` verbatim without interpreting `arg` in any way
- ir `arg` : replace the current stream in the mpv player that has an IPC socket exposed ($AIRING_MPV_IPC_PATH) with `arg`, which can be a channel name or an index
- quit, CTRL+D on empty line : exit the program

Environment variables for configuration purposes:

- AIRING_TERMINAL : graphical terminal emulator to run mpv when IPC interface is not used
- AIRING_USER_TTV : username to default to on start for Twitch.tv
- AIRING_WEECHAT_BUFFER_TTV : name of weechat IRC buffer for Twitch.tv IRC for IPC purposes (joining channels when connected to that IRC)
- AIRING_MPV_IPC_PATH : path to mpv unix domain socket file

# installation
```
$ git clone https://github.com/Muffindrake/airing
$ cd airing
$ nimble build
```

# dependencies
- a recent C compiler
- the Nim compiler as well as its package manager, Nimble - see https://nim-lang.org/
- a TLS library such as openssl
- mpv (currently the only player supported)
- socat (http://www.dest-unreach.org/socat/), for unix domain socket IPC, required for the mpv IPC features
- sh-compatible shell
