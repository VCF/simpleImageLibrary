## Library just to make ANSI color management easier

## Seem to be constantly pulling up ANSI color page:
##    https://en.wikipedia.org/wiki/ANSI_escape_code#Colors
FgBlack="30"
FgRed="31"
FgGreen="32"
FgYellow="33"
FgBlue="34"
FgMagenta="35"
FgCyan="36"
FgWhite="37"
BgBlack="40"
BgRed="41"
BgGreen="42"
BgYellow="43"
BgBlue="44"
BgMagenta="45"
BgCyan="46"
BgWhite="47"
## COLOR NOTE:
##   gnome-terminal appears to use X colors
##   kterm appears to use VGA

if [[ "$TERM" == "xterm" ]]; then
    ## This seems to discriminate between konsole ('xterm') and
    ## gnome-terminal ('xterm-256color').
    BgYellow="103" # Fix ugly yellow background
fi
