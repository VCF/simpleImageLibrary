# Manifest handling functions


function parseManifest {
    ## Parse a manifest file
    path="$1"  # The file we are going to pars
    
    ## Confirm path is ok
    if [[ -z "$path" ]]; then
        die "[!] parseManifest must be provided with a file path as first argument"
    elif [[ ! -f "$path" ]]; then
        die "[!] parseManifest - file not found: $path"
    elif [[ ! -s "$path" ]]; then
        err "[!] parseManifest - file is empty: $path"
    fi

    ## Read the manifest line-by-line
    IFS=''
    while read line; do
        ## Strip out comments. This regexp should also allow us to
        ## include comments at the end of a line
        line="$(echo "$line" | sed 's| *#.*$||')"
        
        if [[ -z "$line" || -n $(echo "$line" | egrep '^ *$') ]]; then
            ## Blank line, don't do anything
            ##  Huh, bash has a no-op: https://stackoverflow.com/a/12405621
            :
        else
            info "$line"
        fi
    done < "$path"
    
}

function processURL {
    
}
