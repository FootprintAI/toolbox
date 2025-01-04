### this script run like scp to copy a entire disk but bypass the limits that opensuse didn't have sftp-server 


```
ssh username@<remote-ip> "sudo tar czf - <remote-folder>" | tar xzvf - -C <local-folder>

```
