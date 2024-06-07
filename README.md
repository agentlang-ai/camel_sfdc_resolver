Salesforce resolver
===================

Resolver based on the Salesforce Camel component.

To use the resolver, the following environment variables must be set:

```shell
SFDC_INSTANCE_URL
SFDC_CLIENT_SECRET
SFDC_CLIENT_ID
```

The `instance-url` should point to the auth-endpoint of SFDC.
`client-id` and `client-secret` can be obtained by creating an SFDC `Connected App`.
The app must OAuth enabled with the following properties set:

```shell
OAuth Scopes (all scopes required to manage data over api)
Callback URL
Require Proof Key for Code Exchange (PKCE) Extension for Supported Authorization Flows	
Require Secret for Web Server Flow	
Require Secret for Refresh Token Flow	
Enable Client Credentials Flow
Client Credentials Flow (a user with the right permissions)
```
