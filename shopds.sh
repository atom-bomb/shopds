#!/bin/sh

# shopds.sh
#
# in-place opds xml generator for e-book collections
# works in bash, ash, dash


# TODO
# include more metadata:
# language
# mobi images
# support lit, pdb
# index by author or title

SCRIPTNAME=$0

TOOLS="grep basename dirname readlink date mktemp unzip sed head find sort md5sum tail strings hexdump"
MISSING_TOOLS=""

ucase() {
  if [ "`which tr`" != "" ]; then
    echo ${1} | tr '[a-z]' '[A-Z]'
  else
    echo ${1^^}
  fi
}

for TOOL in ${TOOLS}; do
  WHICH_TOOL=$(which ${TOOL})
  eval $(ucase ${TOOL})=${WHICH_TOOL}
  if [ "${WHICH_TOOL}" = "" ]; then
    MISSING_TOOLS="${MISSING_TOOLS} ${TOOL}"
  fi
done

if [ "${MISSING_TOOLS}" != "" ]; then
  echo "${SCRIPTNAME} Missing the following tools" >&2
  echo ${MISSING_TOOLS} >&2
  exit 1
fi

PWD=$(pwd)
SCAN_DIR=${PWD}
CATALOG_TITLE="Local E-Books"
CATALOG_AUTHOR=${SCRIPTNAME}
CATALOG_OUTPUT_DIR=${PWD}
CATALOG_OPDS_ROOT_FILENAME="opds"
CATALOG_HTML_ROOT_FILENAME="index.html"
CATALOG_ENABLE_HTML=0

debug() {
  if [ "${VERBOSE}" = "1" ]; then
    echo $@ >&2
  fi
}

error_exit() {
  echo $@ >&2
  exit 1
}

help_exit() {
  echo "${SCRIPTNAME} usage:" >&2
  echo "-h             : print this help and exit" >&2
  echo "-v             : verbose output" >&2
  echo "-m             : generate an html index" >&2
  echo "-o [directory] : specify an alternate output directory" >&2
  echo "-r [filename]  : specify an alternate root filename" >&2
  echo "-i [filename]  : specify an alternate html index filename" >&2
  echo "-t [title]     : specify an alternate catalog title" >&2
  echo "-a [author]    : specify an alternate catalog author" >&2
  echo "-d [directory] : specify an alternate directory to scan" >&2
  exit 1
}

urlencode() {
  local i=1
  local c
  local e=''
  local ok
  while [ ${i} -le ${#1} ]; do
    c=$(expr substr "$1" $i 1)
#    c=${1:$i:1}
    if [ "$c" = ")" ] || [ "$c" = "(" ]; then
      ok=0
    else
      ok=$(expr "$c" : '[a-zA-Z0-9\/\.\~\_\-]')
    fi
    if [ $ok = 0 ]; then
      c=$(printf '%%%02X' "'$c")
    fi
    e="$e$c"
    i=$(( $i + 1 ))
  done
  echo "$e"
}

xmlescape() {
  echo $1 | ${SED} 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g; s/'"'"'/\&#39;/g'
}

html2xhtml() {
  echo $1 | ${SED} 's/<br>/<br \/>/g'
}

epub_metadata() {
  local input_file="$1"
  local metafile
  local metatemp
  local epub_metadata_tags="title creator publisher date subject description"
  local metafound
  local meta

  mime_type="application/epub+zip"
  metafile=$(${UNZIP} -l "${input_file}" | ${GREP} -Eo '\b[^ ]*\.opf\b')

  if [ "${metafile}" = "" ]; then
    debug ${input_file} has no metadata
    return
  fi

  metatemp=$(${MKTEMP} -t epubmetaXXXXXX)
  ${UNZIP} -p "${input_file}" "${metafile}" > ${metatemp}

  for meta in ${epub_metadata_tags}; do
    metafound=$(${GREP} -Eo '<dc:'${meta}'>(.*)</dc:'${meta}'>' ${metatemp})
    if [ "${metafound}" != "" ]; then
      metafound=$(expr "$metafound" : '.*<dc:'${meta}'>\(.*\)</dc:'${meta}'>.*')
      metafound=$(echo ${metafound} | ${SED} 's/"/\&qout;/g; s/'"'"'/\&#39;/g')
      eval ${meta}=\"${metafound}\"
    fi
  done

  if [ "${description}" = "" ]; then
    description=$(${GREP} -Eo '<description xmlns=[^ ]*>.*</description>' ${metatemp})
    if [ "${description}" != "" ]; then
      description=$(expr "${description}" : '<description xmlns=[^ ]*>\(.*\)</description>')
      debug ${description}
    fi
  else
    debug ${description}
  fi

  local cover_ref="$(${GREP} -Eo '<meta .*name="cover".*/>' $metatemp)"
  if [ "${cover_ref}" != "" ]; then
    cover_ref=$(expr "${cover_ref}" : '.*content="\(\S*\)".*')
    local cover_item="$(${GREP} -Eo '<item .*id="'${cover_ref}'".*/>' $metatemp)"
    if [ "${cover_item}" != "" ]; then
      local cover_image=$(expr "${cover_item}" : '.*href="\(\S*\)".*')
      cover_type=$(expr "${cover_item}" : '.*media-type="\(\S*\)".*')

      title_hash=$(echo ${creator}${title} | ${MD5SUM})
      title_hash=${title_hash%%  -}
      cover_file_type="${cover_image##*.}"
      mkdir -p opds_metadata/${title_hash}
      cover_file=opds_metadata/${title_hash}/cover.${cover_file_type}
      debug ${cover_file}
      ${UNZIP} -p "${input_file}" "*${cover_image}" > ${cover_file}
    fi
  fi

  rm -f ${metatemp}
}

pdf_scan_trailer_for() {
  local line 
  local match 
 
  while read line; do
    if [ "${line}" = ">>" ] || [ "${line}" = "startxref" ]; then
      return
    else
      match=$(expr "${line}" : '.*/'${1}' \([[:digit:]]\+ [[:digit:]]\+\) .*')
      if [ "${match}" != "" ]; then
        echo ${match}
      fi
    fi
  done
}

# possible strings
# Title
# Subject
# Keywords
# Author
# CreationDate
# ModDate
# Creator
# Producer
pdf_scan_info_for() {
  local line 
  local match
 
  while read line; do
    if [ "${line}" = ">>" ] || [ "${line}" = "endobj" ]; then
      return
    else
      match=$(expr "${line}" : '.*/'${1}' \?(\([^)]*\))/\?.*')
      if [ "${match}" != "" ]; then
        echo ${match}
      fi
    fi
  done
}

pdf_metadata() {
  local input_file="${1}"
  local pdf_trailer_locs=$(${MKTEMP} -t pdftrailerXXXXXX)
  local trailer_offset
  local trailer_match
  local pdf_object_locs
  local pdf_info_object_loc
  local info_object_offset

  mime_type="application/pdf"

  ${STRINGS} -a -t d "${input_file}" | ${GREP} -E ' trailer$' > ${pdf_trailer_locs}

  if [ $? = 0 ]; then
    while read trailer_offset trailer_match; do
      if [ "${pdf_info_object_loc}" = "" ]; then
        pdf_info_object_loc=$(${TAIL} -c +${trailer_offset} "${input_file}" | tr '\r' '\n' | pdf_scan_trailer_for Info)
      fi
    done < ${pdf_trailer_locs}

    rm -rf ${pdf_trailer_locs}
  else
    local pdf_xref_object_offset

    pdf_xref_object_offset=$( ${TAIL} -n 3 "${input_file}" | ${STRINGS} -a -n 2 | ${GREP} -A 1 "startxref" | ${TAIL} -n 1 )

    pdf_info_object_loc=$(${TAIL} -c +${pdf_xref_object_offset} "${input_file}" | tr '\r' '\n' | pdf_scan_trailer_for Info)
  fi

  debug Info ${pdf_info_object_loc}

  if [ "${pdf_info_object_loc}" = "" ]; then
    debug No info object found
  else
    pdf_object_locs=$(${MKTEMP} -t pdfobjXXXXXX)

    ${STRINGS} -a -t d "${input_file}" | ${GREP} -Eo '[[:digit:]]+ [[:digit:]]+ [[:digit:]]+ obj' > ${pdf_object_locs}

    info_object_offset=$(${GREP} "${pdf_info_object_loc}" ${pdf_object_locs})
    info_object_offset=$(expr "${info_object_offset}" : '\([[:digit:]]\+\) .*')

    rm -rf ${pdf_object_locs}

    debug Info @ ${info_object_offset}

    if [ "${info_object_offset}" = "" ]; then
      debug No info object offset found
    else
      meta=$(${TAIL} -c +${info_object_offset} "${input_file}" | tr '\r' '\n' | tr '\377' ' ' |tr '\376' ' ' | pdf_scan_info_for Title)
      if [ "${meta}" != "" ]; then
        title="${meta}"
      fi

      meta=$(${TAIL} -c +${info_object_offset} "${input_file}" | tr '\r' '\n' | tr '\377' ' ' |tr '\376' ' ' | pdf_scan_info_for Author)
      if [ "${meta}" != "" ]; then
        creator="${meta}"
      fi
    fi
  fi

  local first_image_hdr
  local first_image_hdr_length
  local first_image_offset
  local first_image_length

  first_image_hdr=$(${STRINGS} -a -t d "${input_file}" | ${GREP} -m 1 '/Subtype/Image')
  first_image_offset=$(expr "${first_image_hdr}" : '^[ ]*\([0-9]\+\) .*')
  first_image_length=$(expr "${first_image_hdr}" : '^[ ]*[0-9]\+\ .*/Length \([0-9]\+\)')
  first_image_hdr=$(expr "${first_image_hdr}" : '^[ ]*[0-9]\+ \(.*\)')
  first_image_hdr_length=${#first_image_hdr}

  if [ "${first_image_offset}" != "" ] && [ "${first_image_length}" != "" ]; then
    first_image_offset=$(( ${first_image_offset} + ${first_image_hdr_length} + 3 ))
    title_hash=$(echo ${creator}${title} | ${MD5SUM})
    title_hash=${title_hash%%  -}
    mkdir -p opds_metadata/${title_hash}
    cover_file=opds_metadata/${title_hash}/cover.jpg
    debug ${cover_file}

    ${TAIL} -c +${first_image_offset} "${input_file}" | ${HEAD} -c ${first_image_length} > ${cover_file}
  fi

}

pdf_metadata_from_pdfinfo() {
  local input_file="$1"
  local pdf_metadata_tags="title creator publisher date subject"
  local temp_file=$(${MKTEMP} -t pdfmetaXXXXXX)
  local metafound
  local meta

  mime_type="application/pdf"

  ${PDFINFO} -meta "${input_file}" | tr -d '\n' > ${temp_file}

  for meta in ${pdf_metadata_tags}; do
    metafound=$(${GREP} -Eo '<dc:'${meta}'>(.*)</dc:'${meta}'>' ${temp_file})
    if [ "${metafound}" != "" ]; then
      metafound=$(expr "$metafound" : '.*<dc:'${meta}'>\(.*\)</dc:'${meta}'>.*')
      metafound=$(expr "$metafound" : '.*<rdf:[^>]*>\([^<]*\)</rdf:[^>]*>.*')
      metafound=$(echo ${metafound} | ${SED} -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
      if [ "${metafound}" != "" ]; then
        eval ${meta}=\"${metafound}\"
      fi
    fi
  done

  rm -f ${temp_file}
}

txt_metadata() {
  local input_file="$1"

  local text_start_line=$(${GREP} -En '^\*\*\* START OF THIS PROJECT GUTENBERG EBOOK' "${input_file}")

  mime_type="text/plain"

  if [ "${text_start_line}" != "" ]; then
    local temp_file=$(${MKTEMP} -t txtmetaXXXXXX)
    text_start_line=${text_start_line%%:*}
    ${HEAD} -n ${text_start_line} "${input_file}" > ${temp_file}
    title=$(${GREP} -Eo '^Title: (.*)' ${temp_file})
    title=$(expr "$title" : 'Title: \(.*\)')
    creator=$(${GREP} -Eo '^Author: (.*)' ${temp_file})
    creator=$(expr "$creator" : 'Author: \(.*\)')
    date=$(${GREP} -Eo '^Release Date: (.*) \[' ${temp_file})
    date=$(expr "$date" : 'Release Date: \(.*\) \[')
    rm -f ${temp_file}
  fi
}

html_metadata() {
  local input_file="$1"

  mime_type="text/html"

  titlefound=$(${GREP} -Eo '<title>(.*)<title>' "${input_file}")
  if [ "${titlefound}" != "" ]; then
    titlefound=$(expr "$titlefound" : '.*<title>\(.*\)</title>.*')
    titlefound=$(expr "$titlefound" : '.*<[^>]*>\([^<]*\)</[^>]*>.*')
    if [ "${titlefound}" != "" ]; then
      title="${titlefound}"
    fi
  fi
}

rtf_metadata() {
  local input_file="$1"

  mime_type="application/rtf"
}

doc_metadata() {
  local input_file="$1"

  mime_type="application/msword"
}

cbr_metadata() {
  local input_file="$1"

  mime_type="application/x-cbr"
}

# XXX TODO .acbf metadata?
cbz_metadata() {
  local input_file="$1"
  local cover_image
  local title_hash

  mime_type="application/x-cbz"
  cover_image="$(${UNZIP} -l "${input_file}" | ${GREP} -Eo '[0-9][ ]{3}.*cover\.jpg')"
  if [ "${cover_image}" != "" ]; then
    cover_image=$(expr "${cover_image}" : '[0-9]   \(.*cover\.jpg\)')
    debug ${input_file} cover: ${cover_image}
    title_hash=$(echo ${creator}${title} | ${MD5SUM})
    title_hash=${title_hash%%  -}
    mkdir -p opds_metadata/${title_hash}
    cover_file=opds_metadata/${title_hash}/cover.jpg
    cover_type=image/jpeg
    ${UNZIP} -p "${input_file}" "*${cover_image}" > ${cover_file}
  fi
}

mobi_get_u32be() {
  local input_file="$1"
  local input_offset=$2
  local u32_be_bytes
  local b0
  local b1
  local b2
  local b3

  u32_be_bytes=$(${TAIL} -c +${input_offset} "${input_file}" | ${HEXDUMP} -n 4 -v -e '1/1 "%3u "')
 
  b0=$(expr substr "${u32_be_bytes}" 1 3)
  b1=$(expr substr "${u32_be_bytes}" 5 3)
  b2=$(expr substr "${u32_be_bytes}" 9 3)
  b3=$(expr substr "${u32_be_bytes}" 13 3)

  echo $(( (${b0} << 24) + (${b1} << 16) + (${b2} << 8) + ${b3} ))
}

mobi_get_string() {
  local input_file="$1"
  local input_offset=$2
  local input_length=$3

  ${TAIL} -c +${input_offset} "${input_file}" | ${HEAD} -c ${input_length}
}

mobi_metadata() {
  local input_file="$1"
  local mobi_exth_locs=$(${MKTEMP} -t mobiexthXXXXXX)
  local exth_offset
  local exth_match
  local exth_length
  local exth_records
  local exth_record_offset
  local exth_record_type
  local exth_record_length

  mime_type="application/x-mobipocket-ebook"

  ${STRINGS} -a -t d "${input_file}" | ${GREP} -E 'EXTH' > ${mobi_exth_locs}

  while read exth_offset exth_match; do
    exth_length=$(mobi_get_u32be "${input_file}" $(( ${exth_offset} + ${#exth_match} + 1)) )
    exth_records=$(mobi_get_u32be "${input_file}" $(( ${exth_offset} + ${#exth_match} + 5)) )
    debug EXTH @ ${exth_offset} len ${exth_length}, ${exth_records} records
    exth_record_offset=$(( ${exth_offset} + ${#exth_match} + 9 ))

    while [ ${exth_records} -gt 0 ]; do
      exth_record_type=$(mobi_get_u32be "${input_file}" ${exth_record_offset})
      exth_record_length=$(mobi_get_u32be "${input_file}" $(( ${exth_record_offset} + 4 )) )
      debug EXTH type ${exth_record_type}

      case ${exth_record_type} in
        100)
          # author
          creator=$(mobi_get_string "${input_file}" $(( ${exth_record_offset} + 8 )) $(( ${exth_record_length} - 8 )) )
          debug Author ${creator}
          ;;
        101)
          # publisher
          publisher=$(mobi_get_string "${input_file}" $(( ${exth_record_offset} + 8 )) $(( ${exth_record_length} - 8 )) )
          debug Publisher ${publisher}
          ;;
        103)
          # description
          description=$(mobi_get_string "${input_file}" $(( ${exth_record_offset} + 8 )) $(( ${exth_record_length} - 8 )) )
          debug Description ${description}
          ;;
        105)
          # subject
          subject=$(mobi_get_string "${input_file}" $(( ${exth_record_offset} + 8 )) $(( ${exth_record_length} - 8 )) )
          debug Subject ${subject}
          ;;
        106)
          # date
          date=$(mobi_get_string "${input_file}" $(( ${exth_record_offset} + 8 )) $(( ${exth_record_length} - 8 )) )
          debug Date ${date}
          ;;
        503)
          # title
          title=$(mobi_get_string "${input_file}" $(( ${exth_record_offset} + 8 )) $(( ${exth_record_length} - 8 )) )
          debug Title ${title}
          ;;
      esac

      exth_record_offset=$(( ${exth_record_offset} + ${exth_record_length} ))
      exth_records=$(( ${exth_records} - 1 ))
    done
  done < ${mobi_exth_locs}

  rm -rf ${mobi_exth_locs}
}



file_metadata() {
  local input_file="$1"
  local input_file_ext="${input_file##*.}"

  input_file_ext=$(echo ${input_file_ext} | tr [A-Z] [a-z])
  unset mime_type

  case ${input_file_ext} in
    epub)
      epub_metadata "${input_file}"
      ;;
    pdf)
      pdf_metadata "${input_file}"
      ;;
    txt)
      txt_metadata "${input_file}"
      ;;
    htm)
      html_metadata "${input_file}"
      ;;
    html)
      html_metadata "${input_file}"
      ;;
    rtf)
      rtf_metadata "${input_file}"
      ;;
    doc)
      doc_metadata "${input_file}"
      ;;
    cbr)
      cbr_metadata "${input_file}"
      ;;
    cbz)
      cbz_metadata "${input_file}"
      ;;
    mobi)
      mobi_metadata "${input_file}"
      ;;
    jpg)
      cover_file=$(urlencode "${input_file#${CATALOG_OUTPUT_DIR}}")
      cover_type="image/jpeg"
      ;;
    jpeg)
      cover_file=$(urlencode "${input_file#${CATALOG_OUTPUT_DIR}}")
      cover_type="image/jpeg"
      ;;
    png)
      cover_file=$(urlencode "${input_file#${CATALOG_OUTPUT_DIR}}")
      cover_type="image/png"
      ;;
    gif)
      cover_file=$(urlencode "${input_file#${CATALOG_OUTPUT_DIR}}")
      cover_type="image/gif"
      ;;
  esac

  if [ "${mime_type}" != "" ]; then
     local href=$(urlencode "${input_file#${CATALOG_OUTPUT_DIR}}")
     acquisition_href_list="${acquisition_href_list} ${href}"
     acquisition_type_list="${acquisition_type_list} ${mime_type}"
  fi
}

reset_metadata() {
  unset title
  unset creator
  unset publisher
  unset date
  unset subject
  unset description
  unset mime_type
  unset acquisition_href_list
  unset acquisition_type_list
  unset cover_file
  unset cover_type
}

default_metadata() {
  local input_file="$1"
  local input_file_ext=${input_file##*.}

  title=$( ${BASENAME} "${input_file%*.${input_file_ext}}" )
  creator=$( ${BASENAME} "$( ${DIRNAME} "$( ${READLINK} -f "${input_file}" )")")
}

html_catalog_header() {
  echo '<html><head>'
  echo "<title>${CATALOG_TITLE}</title>"
  echo "<style>"
  echo ".cover { width:80px; float:left; position:relative; bottom:10px; }"
  echo ".title { text-decoration: underline }"
  echo ".entry { border:thin; border-style:solid; clear:both; overflow:auto; }"
  echo ".content { font-style:italic }"
  echo "</style>"
  echo "</head><body>"
}

html_catalog_entry() {
  if [ "${acquisition_href_list}" = "" ]; then
    return
  fi

  echo "<div class=\"entry\"><p>"

  if [ "${cover_file}" != "" ]; then
    echo "<img src=\"${cover_file}\" alt=\"cover\" class=\"cover\"\">"
  fi

  if [ "${title}" != "" ]; then
    echo "<p class=\"title\">$(xmlescape "${title}")</p>"
  fi

  if [ "${creator}" != "" ]; then
    echo "<p class=\"creator\">$(xmlescape "${creator}")</p>"
  fi

  if [ "${publisher}" != "" ]; then
    echo "<p class=\"publisher\">$(xmlescape "${publisher}")</p>" 
  fi

  if [ "${date}" != "" ]; then
    echo "<p class=\"date\">${date}</p>"
  fi

  echo "</p>"


  if [ "${description}" != "" ]; then
    echo "<p class=\"description\">"$(html2xhtml "${description}")"</p>"
  fi


  local remaining_href_list="${acquisition_href_list}"
  local remaining_type_list="${acquisition_type_list}"

  while [ "${remaining_href_list}" != "" ]; do
    this_href=${remaining_href_list%% *}
    this_mime_type=${remaining_type_list%% *}

    if [ "${this_href}" != "" ]; then
      echo "<a href=\"${this_href}\" class=\"content\">"
      echo "${this_mime_type}</a>"
    fi

    remaining_href_list=${remaining_href_list#* }
    remaining_type_list=${remaining_type_list#* }
    if [ "${remaining_href_list}" = "${this_href}" ]; then
      remaining_href_list=""
    fi
  done

  echo "</div>"
}

html_catalog_footer() {
  echo "</body></html>"
}

opds_catalog_header() {
  echo '<?xml version="1.0" encoding="UTF-8"?>'
  echo '<feed xmlns="http://www.w3.org/2005/Atom"'
  echo ' xmlns:dc="http://purl.org/dc/terms/"'
  echo ' xmlns:opds="http://opds-spec.org/2010/catalog">'

  echo "<title>${CATALOG_TITLE}</title>"
  echo "<updated>$(${DATE})</updated>"
  echo "<author>"
  echo "  <name>${CATALOG_AUTHOR}</name>"
  echo "</author>"
  echo
}

opds_catalog_footer() {
  echo '</feed>'
}

opds_entry() {
  if [ "${acquisition_href_list}" = "" ]; then
    return
  fi

  echo '<entry>'

  if [ "${title}" != "" ]; then
    echo "<title>$(xmlescape "${title}")</title>"
  fi

  if [ "${creator}" != "" ]; then
    echo "<author><name>$(xmlescape "${creator}")</name></author>"
  fi

  if [ "${publisher}" != "" ]; then
    echo "<dc:publisher>$(xmlescape "${publisher}")</dc:publisher>" 
  fi

  if [ "${date}" != "" ]; then
    echo "<dc:issued>${date}</dc:issued>"
  fi

  if [ "${description}" != "" ]; then
    echo "<content type=\"html\">"$(html2xhtml "${description}")"</content>"
  fi

  if [ "${cover_file}" != "" ]; then
    echo "<link rel=\"http://opds-spec.org/image\""
    echo " href=\"${cover_file}\""
    echo " type=\"${cover_type}\"/>"
  fi

  local remaining_href_list="${acquisition_href_list}"
  local remaining_type_list="${acquisition_type_list}"

  while [ "${remaining_href_list}" != "" ]; do
    this_href=${remaining_href_list%% *}
    this_mime_type=${remaining_type_list%% *}

    if [ "${this_href}" != "" ]; then
      echo "<link rel=\"http://opds-spec.org/acquisition\""
      echo " href=\"${this_href}\""
      echo " type=\"${this_mime_type}\"/>"
    fi

    remaining_href_list=${remaining_href_list#* }
    remaining_type_list=${remaining_type_list#* }
    if [ "${remaining_href_list}" = "${this_href}" ]; then
      remaining_href_list=""
    fi
  done

  echo '</entry>'
}

while getopts ":vhd:t:a:o:r:i:m" opt; do
  case $opt in
    v)
      VERBOSE=1
      debug "Verbose Mode"
      ;;
    h)
      help_exit
      ;;
    o)
      CATALOG_OUTPUT_DIR=${OPTARG}
      debug "Catalog Output Dir" ${CATALOG_OUTPUT_DIR}
      ;;
    r)
      CATALOG_OPDS_ROOT_FILENAME=${OPTARG}
      debug "Catalog OPDS root" ${CATALOG_OPDS_ROOT_FILENAME}
      ;;
    i)
      CATALOG_HTML_ROOT_FILENAME=${OPTARG}
      debug "Catalog HTML index" ${CATALOG_HTML_ROOT_FILENAME}
      CATALOG_ENABLE_HTML=1
      ;;
    m)
      debug "Catalog HTML index" ${CATALOG_HTML_ROOT_FILENAME}
      CATALOG_ENABLE_HTML=1
      ;;
    t)
      CATALOG_TITLE=${OPTARG}
      debug "Catalog Title" ${CATALOG_TITLE}
      ;;
    a)
      CATALOG_AUTHOR=${OPTARG}
      debug "Catalog Author" ${CATALOG_AUTHOR}
      ;;
    d)
      SCAN_DIR=${OPTARG}
      debug "Scan " ${SCAN_DIR}
      ;;
    \?)
      error_exit "Invalid option: -$OPTARG"
      ;;
    :)
      error_exit "Option -$OPTARG requires an argument."
  esac
done

SCAN_LIST_FILE=$(${MKTEMP} -t opdsXXXXXX)

${FIND} "${SCAN_DIR}" -type f | ${SORT} > ${SCAN_LIST_FILE}

opds_catalog_header > ${CATALOG_OPDS_ROOT_FILENAME}

if [ "${CATALOG_ENABLE_HTML}" = "1" ]; then
  html_catalog_header > ${CATALOG_HTML_ROOT_FILENAME}
fi

LAST_FILE_NAME=""

while read NEXT_FILE; do
  debug ${NEXT_FILE}
  NEXT_FILE_TYPE="${NEXT_FILE##*.}"
  NEXT_FILE_NAME="${NEXT_FILE%*.${NEXT_FILE_TYPE}}"

  if [ "${NEXT_FILE_NAME}" != "${LAST_FILE_NAME}" ]; then
    opds_entry >> ${CATALOG_OPDS_ROOT_FILENAME}
    if [ "${CATALOG_ENABLE_HTML}" = "1" ]; then
      html_catalog_entry >> ${CATALOG_HTML_ROOT_FILENAME}
    fi
    reset_metadata
    LAST_FILE_NAME="${NEXT_FILE_NAME}"
    default_metadata "${NEXT_FILE}"
  fi 

  file_metadata "${NEXT_FILE}"
done < ${SCAN_LIST_FILE}

opds_entry >> ${CATALOG_OPDS_ROOT_FILENAME}

if [ "${CATALOG_ENABLE_HTML}" = "1" ]; then
  html_catalog_entry >> ${CATALOG_HTML_ROOT_FILENAME}
fi

opds_catalog_footer >> ${CATALOG_OPDS_ROOT_FILENAME}

if [ "${CATALOG_ENABLE_HTML}" = "1" ]; then
  html_catalog_footer >> ${CATALOG_HTML_ROOT_FILENAME}
fi

rm -f ${SCAN_LIST_FILE}
