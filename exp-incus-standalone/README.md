# exp-incus-standalone
Experiment example for an Incus standalone host

## Notes

Export trusted certs form one incus host to add them to differnet incus host
```bash
# Display the certificate being used by the incus CLI client
incus remote get-client-certificate

# Display a short list of all trusted certs
incus config trust list

# Export all trusted certs as commands to import into a different incus host
incus query '/1.0/certificates?recursion=1' | jq -r '.[] | select(.type=="client") | "incus config trust add-certificate <(printf %s \(.certificate|@sh)) --name \(.name|@sh)"'
```

Create a system container to demonstrate the functionality
```bash
# List all instances
incus list

# Launch a system container
incus launch images:ubuntu/resolute c1
```
