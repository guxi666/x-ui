#!/bin/bash

set -e

bash <(curl -Ls https://raw.githubusercontent.com/guxi666/x-ui/main/deploy.sh) "$@"
