#!/bin/sh

cd `dirname $0`

if [ -f .env ]
then
  export $(cat .env | xargs)
fi

dub run

