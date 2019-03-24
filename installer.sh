#!/bin/sh
set -e

function connection_details {
    echo -n "Enter your Prism Central IP address and press [ENTER]: "
    read ip
    export JG_IP=$ip

    echo -n "Enter your PC username and press [ENTER]: "
    read username
    export JG_USERNAME=$username

    printf "Enter your PC password and press [ENTER]: "
    read_secret password
    export JG_PASSWORD=$password

    echo -n "Enter the GitHub repo (user/repo) and press [ENTER]: "
    read project
    export JG_GIT_REPO=$project

    echo -n "Enter your Calm project and press [ENTER]: "
    read project
    export JG_PROJECT=$project
}

function read_secret {
    # Disable echo.
    stty -echo

    # Set up trap to ensure echo is enabled before exiting if the script
    # is terminated while echo is disabled.
    trap 'stty echo' EXIT

    # Read secret.
    read "$@"

    # Enable echo.
    stty echo
    trap - EXIT

    # Print a newline because the newline entered by the user after
    # entering the passcode is not echoed. This ensures that the
    # next line of output begins at a new line.
    echo
}

function get_repo {
python - <<END
import requests
import os

repo = os.environ['JG_GIT_REPO']

url = "https://api.github.com/repos/" + repo + "/contents"
response = requests.request("GET", url)
data = response.json()

directories = []
for item in data:
    if item['type'] == 'dir':
        directories.append(item['name'].encode('utf-8'))

# Convert Python list into Shell array
x = ' '.join(directories)

print x
END
}

function download_blueprints {
python - <<END
import requests
import os

bp = os.environ['CALM_BLUEPRINTS'].split(" ")
repo = os.environ['JG_GIT_REPO']

urls = []
for i in bp:
    resp = requests.get('https://api.github.com/repos/' + repo + '/contents/' + i)
    data = resp.json()
    for y in data:
        if "json" in y['name']:
          urls.append(y['download_url'].encode('utf-8'))

x = ' '.join(urls)

print x
END
}

function import_blueprints {
python - <<END
import requests
import json
import os

from requests.auth import HTTPBasicAuth
from time import localtime, strftime, mktime

def get_options():
    # process the command-line parameters provided by the user
    global cluster_ip
    global username
    global password
    global project
    global base_url

    # mappint env variables to mandatory inputs

    if os.environ['JG_USERNAME']:
        username = os.environ['JG_USERNAME']

    if os.environ['JG_PASSWORD']:
        password = os.environ['JG_PASSWORD']

    if os.environ['JG_PROJECT']:
        project = os.environ['JG_PROJECT']

    cluster_ip = os.environ['JG_IP']
    base_url = 'https://' + cluster_ip + ':9440/api/nutanix/v3'

def main():
    
    get_options()

    headers = {'Content-Type': 'application/json; charset=utf-8'}

    if not cluster_ip:
        raise Exception("Cluster IP is required.")
    elif not username:
        raise Exception("Username is required.")
    elif not password:
        raise Exception("Password is required.")
    else:
        blueprint_download_urls = os.environ['JG_BLUEPRINTS_URLS'].split(" ")

        if(len(blueprint_download_urls) > 0):
            if project != 'none':
                payload = "{\"kind\": \"project\"}"
                url = base_url + '/projects/list'
                project_found = False
                r = requests.post(url, data=payload, verify=False, headers=headers, auth=HTTPBasicAuth(username, password), timeout=60)
                data = r.json()
                for current_project in data['entities']:
                    if current_project['status']['name'] == project:
                        project_found = True
                        project_uuid = current_project['metadata']['uuid']

                        #print(project_uuid)
            
            # was the project found?
            if project_found:
                print('Project', project, 'exists')
            else:
                # project wasn't found
                # exit at this point as we don't want to assume all blueprints should then hit the 'default' project
                print('Project', project, 'was not found.  Please check the name and retry.')
                sys.exit()

            # make sure the user knows what's happening ... ;-)
            print(len(blueprint_download_urls), 'JSON files found. Starting import ...')
            
            # go through the blueprint JSON files found in the specified directory
            for blueprint in blueprint_download_urls:
                start_time = localtime()
                # open the JSON file from Internet
                r = requests.get(blueprint)
                
                if project != 'none':
                    parsed = json.loads(r.text)
                    parsed["metadata"]["project_reference"] = {}
                    parsed["metadata"]["project_reference"]["kind"] = "project"
                    parsed["metadata"]["project_reference"]["uuid"] = project_uuid
                    raw_json = json.dumps(parsed)
                    
                # remove the "status" key from the JSOn data
                # this is included on export but is invalid on import
                pre_process = json.loads(raw_json)
                if "status" in pre_process:
                    pre_process.pop("status")
                
                # after removing the non-required keys, make sure the data is back in the correct format
                raw_json = json.dumps(pre_process)

                # try and get the blueprint name
                # if this fails, it's either a corrupt/damaged/edited blueprint JSON file or not a blueprint file at all
                """
                try:
                """
                blueprint_name = json.loads(raw_json)['spec']['name']
                """
                except ValueError:
                    print(blueprint, 'Unprocessable JSON file found. Is this definitely a Nutanix Calm blueprint file?')
                    sys.exit()
                """
                
                # got the blueprint name - this is probably a valid blueprint file
                # we can now continue and try the upload
                payload = raw_json
                url = base_url + '/blueprints/import_json'
                r = requests.post(url, data=payload, verify=False, headers=headers, auth=HTTPBasicAuth(username, password), timeout=60)
                """
                try:
                    json_result = r.text()
                except ValueError:
                    print(blueprint, ': No processable JSON response available.')
                    sys.exit()
                """

if __name__ == "__main__":
    main()

END
}

connection_details

# Call Python function to retrieve folders in GitHub repo
options=($(get_repo))

menu() {
    echo "Avaliable options:"
    for i in ${!options[@]}; do
        printf "%3d%s) %s\n" $((i+1)) "${choices[i]:- }" "${options[i]}"
    done
    [[ "$msg" ]] && echo "$msg"; :
}

prompt="Check an option (again to uncheck, ENTER when done): "
while menu && read -rp "$prompt" num && [[ "$num" ]]; do
    [[ "$num" != *[![:digit:]]* ]] &&
    (( num > 0 && num <= ${#options[@]} )) ||
    { msg="Invalid option: $num"; continue; }
    ((num--)); msg="${options[num]} was ${choices[num]:+un}checked"
    [[ "${choices[num]}" ]] && choices[num]="" || choices[num]="+"
done

printf "You selected"; msg=" nothing"
for i in ${!options[@]}; do 
    [[ "${choices[i]}" ]] && { printf " %s" "${options[i]}"; msg=""; }
done
echo "$msg"

if [ "$msg" != " nothing" ]; then
  BLUEPRINTS=()
  for i in ${!options[@]}; do
      [[ "${choices[i]}" ]] && BLUEPRINTS+=(${options[i]})
  done

  export CALM_BLUEPRINTS="${BLUEPRINTS[@]}"

  export JG_BLUEPRINTS_URLS=$(download_blueprints)

  if [ "$JG_BLUEPRINTS_URLS" != "" ]; then
      import_blueprints
  else
      echo "There are no blueprints in the repository to import"
  fi
fi
