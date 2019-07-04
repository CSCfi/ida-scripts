# This repository was made for an older version of IDA which is no longer in use

iput_wrapper
========

Wrapper for uploading files using iput for iRODS 4.X.X clients.
             
Handles logging, checksum/size checking, iput 'large file retries', wildcards,
deep directory creation, skipping existing files (when checksums and sizes match),
skipping existing directories, etc.                                           
                                                                              
The purpose is to:                                                            

1. Imitate irsync, which is buggy and missing most of the features of iput   
2. Create detailed log entries of transfers (creation of directories,        
   individual file transfer errors, checksum comparisons)                    
3. Force users to use best practices when tranferring files (avoid using     
   recursive transfers, compare checksums, etc.)                             
4. Help in transferring large directories                                    
5. Provide iRODS operators better logging for debugging user file            
   transfers assuming users remember/are able to use the wrappper and        
   are able to provide the transfer logs                                     
                                                                              
Requirements
------------

* iRODS 4.X.X iCommands CLI
* bash 4.2

Usage
-----

Set the execute bit for the script
```
$ chmod 755 iput_wrapper.bash
```
Execute the script without parameters to get the help text
```
$ ./iput_wrapper.bash
```

License
-------

MIT

Author Information
------------------

Taneli Riitaoja 2015-2016  

