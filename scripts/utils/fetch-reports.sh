#!/bin/bash

mkdir -p ./reports

for i in {0..41}; do 
	if [[ ! -d "./reports/wp$i" ]]; then
		mkdir -p "./reports/wp$i";
	fi;

	echo "Copying wp$i report to ./reports/wp$i";

	scp root@wp$i.ciwgserver.com:/var/opt/wp-plugin-update-reports/wp_plugins_report.pdf ./reports/wp$i/wp_plugins_report.pdf; \
done

echo "All reports copied to ./reports directory."