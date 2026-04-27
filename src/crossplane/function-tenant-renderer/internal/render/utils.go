package render

import (
	"fmt"

	"github.com/google/uuid"
)

func GenerateAppRoleUUID(tenant, role, env string) string {
	seed := fmt.Sprintf("%s-%s-%s", tenant, role, env)
	return uuid.NewSHA1(uuid.NameSpaceDNS, []byte(seed)).String()
}
