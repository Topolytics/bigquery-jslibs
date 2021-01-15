#!/bin/bash

### START OF SETTINGS ###

# projectid is your Project for the functionality
# gsbucket is your Bucket to store the functionality
# regions array of regions to deploy to which will use a REGION_ prefix on the functions names. 
# The "default_" prefix is used to denote the default region which will omit the prefix.

projectid="internal-tp0uk-server-1"
gsbucket="topo-bigquery-jslibs"
regions=( us eu default_europe-west2 )

### END OF SETTINGS ###

#Deploy JS libraries
gsutil cp libs/*  gs://$gsbucket/

#create datsets if it does not exist Datasets in all regions
ls sql | sort -z|while read libname; do
  #we iterate over the regions
  for reg in "${regions[@]}"
  do
    #we create the daset with no region for backwards compatibility
    IFS='_' read -a REG <<< "$reg"
    if [[ "${REG[0]}" == "default" ]];
    then
      region="${REG[1]}"
      datasetname="$libname"
    else
      region="${REG[0]}"
      datasetname="${region}_${libname}"
    fi

    #create the dataset
    bq --project_id="$projectid" --location="$region" mk -d \
    --description "Dataset in ${region} for functions of library: ${libname}" \
    "$datasetname"

    #To add allAuthenticatedUsers to the dataset we grab the just created permission
    bq --project_id="$projectid" show --format=prettyjson \
    $projectid:"$datasetname" > permissions.json
  
    #add the permision to temp file
    sed  '/"access": \[/a \ 
    {"role": "READER","specialGroup": "allAuthenticatedUsers"},' permissions.json > updated_permission.json

    #we update with the new permissions file
    bq --project_id="$projectid" update --source updated_permission.json $projectid:"$datasetname"

    #cleanup
    rm updated_permission.json
    rm permissions.json
  done
done


#We go over all the SQLs and replace for example jslibs.s2. with jslibs.eu_s2.
#BIT HACKY

#Iterate over all SQLs and run them in BQ
find "$(pwd)" -name "*.sql" | sort  -z |while read fname; do
  echo "$fname"
  DIR=$(dirname "${fname}")
  libname=$(echo $DIR | sed -e 's;.*\/;;')
  file_name=$(basename "${fname}")
  function_name="${file_name%.*}"

  #we iterate over the regions to update or create all functions in the different regions
  for reg in "${regions[@]}"
  do
    IFS='_' read -a REG <<< "$reg"
    if [[ "${REG[0]}" == "default" ]];
    then
      datasetname="${libname}"
      function_prefix=""
    else
      datasetname="${reg}_${libname}"
      function_prefix="${REG[0]}_"
    fi
    
    # Strings to match - this takes care of all of the aspects of the sql files as-is. 
    # NOTE: The sql files could be updated to be easier to manipluate 

    # Update the full function name
    search1="jslibs.${libname}.${function_name}"
    replace1="\`${projectid}\`.${datasetname}.${function_name}"

    # Update the bucket location of where to find the function code
    search2="bigquery-jslibs"
    replace2="${gsbucket}"

    # Update function call references to jslibs. to use `project`. instead
    search3="jslibs\."
    replace3="\`${projectid}\`.${function_prefix}"

    echo "CREATING OR UPDATING ${replace1}"

    sed "s/${search1}/${replace1}/g; s/${search2}/${replace2}/g; s/${search3}/${replace3}/g" $fname > tmp.file
    bq  --project_id="${projectid}" query --use_legacy_sql=false --flagfile=tmp.file
    rm tmp.file

  done
done

