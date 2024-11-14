#!/bin/bash

# wp81in.sh - v. 1.4 (2024)
# A script to install WordPerfect 8.1 for Linux 
# on debian-based systems.
# \(c\) Peter Stone, 2024
# peter@xwp8users.com

####  WoodardDigital comment 
#### Taken from Peter's stuff,  put in this repo to  install for my dad

bold=$(tput bold)
normal=$(tput sgr0)

echo " "
echo This script is designed to install ${bold}WordPerfect 8.1 for Linux${normal} on a 
echo debian-based distro current in 2024 or later. 
echo " " 
echo It has been tested on Mint 22, a 64-bit distro. 
echo " " 
echo Before running this script, you should have taken the following
echo preliminary steps:
echo " "
echo 1. Create the following directory, which will serve as the working 
echo "directory for the script:  "${bold}~/Downloads/wp-inst${normal}
echo " "
echo 2. Copy this script file to that directory.
echo
echo 3. Copy your wp8-full and fonts-x deb files, or your wpx-free deb file, 
echo from your Corel Linux cd to that directory.
echo " "
echo " "
echo The script should be run as a normal user. It will call for your sudo 
echo password on the first occasion that \"sudo\" is called. 
echo " "
echo After changing to the working directory, the script can be executed 
echo "with the command:  "${bold}sh ./wp81in.sh${normal}

# *****************************************************************************
# Carrying out preliminary steps (mainly tests and downloads)

echo " "
# Ensuring that the working directory exists.

test -e ~/Downloads/wp-inst
if ! [ $? = 0 ] 
then 
   mkdir ~/Downloads/wp-inst
fi

cd ~/Downloads/wp-inst

echo " "
# Testing for the WordPerfect 8.1 deb.

test -e ./wp-full_8.1-12_i386.deb 
if [ $? = 0 ] 
then 
     test -e ./fonts-16_1.0-5.deb
     if ! [ $? = 0 ] 
     then 
        echo " "
        echo "Command failed. fonts-16 is not available. Exiting script."
        exit
     fi

     cp ./wp-full_8.1-12_i386.deb ./wp81.deb

     else 
     test -e ./wpx-free_8.0-78_i386.deb
     if [ $? = 0 ] 
     then 
         cp ./wpx-free_8.0-78_i386.deb ./wp81.deb
     else
         echo " "
         echo "Command failed. No version of WordPerfect 8.1 is available. Exiting script."
        exit
    fi
fi

echo " "
# Now installing wget deb.

sudo apt-get -y install wget

if ! [ $? = 0 ] 
then 
   echo " "
   echo "Command failed. Unable to install wget. Exiting script."
   exit
fi

# Now installing libxaw7:i386.

echo " "
sudo apt install libxaw7:i386

if ! [ $? = 0 ] 
then 
    echo "Command failed. Unable to install libxaw7. Exiting script."
    exit
fi

# Removing packages which conflict with wp-utils.
# In version 3.7 onwards, wp-utils itself deals with libc5 requirements.

sudo dpkg -r wppmwrap wppmwrap80 wppmwrap81d wppmwrap-80 wppmwrap-81d
sudo dpkg -r xlib6g type1inst type1-64add prewp64 prewp68 wputils80
sudo dpkg -r ldso libc5

echo " "
# Downloading the wp-utils deb, if necessary.

test -e ./wp-utils_3.7_i386.deb
if ! [ $? = 0 ] 
then 
    wget http://www.xwp8users.com/packages/wp-utils_3.7_i386.deb
fi
  
if ! [ $? = 0 ] 
then 
    echo " "
    echo "Command failed. wp-utils is not available. Exiting script."
    exit
fi

echo " "
# Now installing wp-utils.

sudo dpkg -i wp-utils_3.7_i386.deb

if ! [ $? = 0 ] 
then 
    echo "Command failed. Unable to install wp-utils. Exiting script."
    exit
fi

sudo chmod +x /usr/bin/installpkg
sudo chmod +x /usr/bin/type1inst
sudo chmod +x /usr/bin/xwppmgr
sudo chmod +x /usr/bin/xwppmgr81
sudo chmod +x /usr/bin/xwppmgr80
sudo chmod +x /lib/ld-2.27.so

echo " "
# Now installing libc6:i386.

sudo apt-get -y install libc6:i386

if ! [ $? = 0 ] 
then 
    echo " "
    echo "Command failed. Unable to install libc6:i386. Exiting script."
    exit
fi

echo " "
# Now running ldconfig.

sudo ldconfig -c old

if ! [ $? = 0 ] 
then 
    echo " "
    echo "Command failed. Unable to run ldconfig. Exiting script."
    exit
fi

# *******************************************************************
# Now installing some official support packages.

echo " "
# Now installing alien.

sudo apt-get -y install alien

if ! [ $? = 0 ] 
then 
    echo " "
    echo "Command failed. Unable to install alien. Exiting script."
    exit
fi

echo " "
# Now installing groff.

sudo apt-get -y install groff

if ! [ $? = 0 ] 
then 
    echo " "
    echo "Command failed. Unable to install groff. Exiting script."
    exit
fi

echo " "
# Now installing perl.

sudo apt-get -y install perl

if ! [ $? = 0 ] 
then 
    echo " "
    echo "Command failed. Unable to install perl. Exiting script."
    exit
fi

echo " "
# Now installing xbase-clients.

sudo apt-get -y install xbase-clients

if ! [ $? = 0 ] 
then 
    echo " "
    echo "Command failed. Unable to install xbase-clients. Exiting script."
    exit
fi

cd ~/Downloads/wp-inst

echo " "

# ****************************************************************************
# Now proceeding with the main installation.
# Now installing fonts for wp-full.

test -e ./wp-full_8.1-12_i386.deb 
if [ $? = 0 ] 
then 
    test -e ./fonts-16_1.0-5.deb
    if [ $? = 0 ] 
    then 
        sudo alien -t ./fonts-16_1.0-5.deb
 
        if ! [ $? = 0 ] 
        then 
            echo " "
            echo "Command failed. fonts-16 cannot be converted. Exiting script."
            exit
        fi
           
        sudo installpkg ./fonts-16-1.0.tgz

        if ! [ $? = 0 ] 
        then 
            echo " "
            echo "Command failed. Unable to install fonts-16. Exiting script."
            exit
        fi
    fi      
fi
      
test -e ./wp-full_8.1-12_i386.deb 
if [ $? = 0 ] 
then 
    echo " "
    test -e ./fonts-69_1.0-4.deb
    if [ $? = 0 ] 
    then 
        sudo alien -t ./fonts-69_1.0-4.deb

        if [ $? = 0 ] 
        then 
            sudo installpkg ./fonts-69-1.0.tgz
        fi             
    fi
fi

test -e ./wp-full_8.1-12_i386.deb 
if [ $? = 0 ] 
then 
    echo " "
    test -e ./fonts-115_1.0-4.deb
    if [ $? = 0 ] 
    then 
        sudo alien -t ./fonts-115_1.0-4.deb

        if [ $? = 0 ] 
        then 
            sudo installpkg ./fonts-115-1.0.tgz
        fi
    fi       
fi

echo " "

cd ~/Downloads/wp-inst

# ****************************************************************************
# Now converting and then installing the core WordPerfect package.

sudo alien -t ./wp81.deb

if ! [ $? = 0 ] 
then 
    echo " "
    echo "Command failed. Unable to convert the core WordPerfect package."
    echo "Exiting script."
    exit
fi

test -e ./wp-full-8.1.tgz
if [ $? = 0 ] 
then 
    mv ./wp-full-8.1.tgz ./wp81.tgz

else
    test -e ./wpx-free-8.0.tgz
    if [ $? = 0 ] 
    then 
        mv ./wpx-free-8.0.tgz ./wp81.tgz
    fi
fi    
    
sudo installpkg ./wp81.tgz

if ! [ $? = 0 ] 
then
    echo "Command failed. Unable to install the core WordPerfect code." 
    echo "Exiting script."
    exit
fi     
    
# Now co-ordinating with 8.0, if necessary.

sudo cp /usr/bin/xwp /usr/bin/xwp81

cd ~/Downloads/wp-inst

echo " "

# ***********************************************************************
# Now setting up the fonts.

test -e /usr/lib/wp8/shbin10/wpfi
if [ $? = 0 ] 
then 
    cd /usr/X11R6/lib/X11/fonts/Type1

    sudo type1inst

    if ! [ $? = 0 ] 
    then 
        echo " "
        echo "Command failed. Unable to run type1inst. Exiting script."
        exit
    fi

    sudo mkfontdir

    if ! [ $? = 0 ] 
    then 
        echo " "
        echo "Command failed. Unable to run mkfontdir. Exiting script."
        exit
    fi

    sudo /usr/lib/wp8/shbin10/wpfi

    if ! [ $? = 0 ] 
    then 
        echo " "
        echo "Command failed. Unable to run wpfi. Exiting script."
        exit
    fi

    sudo cp -RT /usr/X11R6/lib/X11/fonts/Type1 /usr/share/fonts/type1

    if ! [ $? = 0 ] 
    then 
        echo " "
        echo "Command failed. Unable to copy fonts to the whole system." 
        echo "Exiting script."
        exit
    fi  
fi

cd ~/Downloads/wp-inst

echo " "

# Now creating a link to /etc/printcap, if necessary.

test -e /etc/printcap
if ! [ $? = 0 ] 
then 
    sudo ln -s /run/cups/printcap /etc/printcap
fi

# *****************************************************************************
# Now setting up the WP Print Manager executable.

echo " "
cd /usr/lib/wp8/shbin10

test -e ./xwppmgr.bin
if ! [ $? = 0 ] 
then 
    sudo cp ./xwppmgr ./xwppmgr.bin
fi

test -e ./xwppmgr.bin
if ! [ $? = 0 ] 
then 
    echo " "
    echo "Command failed. Unable to create xwppmgr.bin."
    echo "Exiting script."
    exit
fi

sudo ldconfig -c old

# **********************************************************************
# Now providing the final messages

echo " "
echo \(1\) ${bold}WordPerfect 8.1${normal} has been successfully installed, along with an updated 
echo version of the WP Print Manager.
echo " "
echo \(2\) You should now be able to run WordPerfect 8.1 as a normal user, by giving, 
echo "in a terminal window, the command:  "\"${bold}xwp${normal}\"
echo " "
echo Preferably the command should be given from your home directory.
echo " "
echo You can also run WordPerfect from the Office folder in your Linux menu.
echo " "
echo \(3\) If, when first running WordPerfect, you get an error referring to 
echo \"too many processes\", you should run WordPerfect once as administrator.
echo " "
echo This can be done by giving, in a terminal window, 
echo "the command:  "\"${bold}sudo xwp -adm${normal}\"
echo " "
echo \(4\) To run the WP Print Manager, you can give \(in a terminal window\) 
echo "the command:  "\"${bold}sudo xwppmgr${normal}\"
echo " "
echo " "
echo Enjoy!
echo " "
exit
