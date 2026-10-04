run:
	docker compose --profile exit-node up -d --build

upstream-pull:
	git fetch upstream
	git checkout main
	git merge upstream/main
	git push origin main
	git checkout test
	git merge main
