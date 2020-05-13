#!/bin/bash 

_file="file"
_search="search"

_bold="\e[1m"
_green="\e[32m"
_yellow="\e[33m"
_blue="\e[34m"
_reset="\e[0m"

function dotail()
{
	sudo tail -f -n 1000 $_file | grep --color -E "$_search|$"
}

if (( $# <= 1 )); then
    printf "
    Script to tail a file and highlight for searched word.
    
    $_green Usage: $_reset 
    	$_blue tail-highlight.sh $_green <<file>> <<search_for>> $_reset 
    	$_bold example simple: $_reset $_blue tail-highlight.sh $_green catalina.out hibernate $_reset
    	$_bold example multiple words: $_reset $_blue tail-highlight.sh $_green catalina.out 'hibernate|select' $_reset
    	
    "
    echo
else
	_file=$1
	_search=$2
	dotail  
fi


