#!/bin/bash

# Prompt for the input file containing URLs
read -p "Enter the path to the file containing URLs: " url_file

# Check if the file exists
if [[ ! -f "$url_file" ]]; then
    echo "The file $url_file does not exist."
    exit 1
fi

# Prompt for the destination directory
read -p "Enter the destination directory for downloads: " dest_dir

# Create the directory if it does not exist
mkdir -p "$dest_dir"

# Check if wget is installed
if ! command -v wget &> /dev/null; then
    echo "wget could not be found, please install it or use a system where it is installed."
    exit 1
fi

# Read each URL from the file and download it
while IFS= read -r url; do
    echo "Downloading $url..."
    wget -P "$dest_dir" "$url"
done < "$url_file"

echo "All files have been downloaded to $dest_dir."
