**The flow when a tenant operator runs `vault login -method=oidc`**
1. The Vault CLI starts a tiny temporary web server on the operator's own machine at localhost:8250.
2. The CLI opens the operator's browser to Entra to sign in.
3. Entra authenticates the user.
4. Entra redirects the browser back to localhost:8250 on the operator's machine with the auth code.
5. The CLI's local server catches the code.
6. The CLI exchanges that code with Entra for a token.
7. The CLI then presents that token to the Vault server.
