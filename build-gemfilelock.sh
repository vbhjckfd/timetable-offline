docker run --rm -v $(pwd):/usr/src/app -w /usr/src/app ruby:3.1-alpine /bin/sh -c "apk add --no-cache git && bundle lock"