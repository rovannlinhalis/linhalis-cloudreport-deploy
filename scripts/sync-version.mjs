import { readFile, writeFile } from 'node:fs/promises'
import process from 'node:process'

const repository = process.env.CLOUDREPORT_DOCKERHUB_REPOSITORY ?? 'rovann/cloudreport'
const manifestPath = process.env.CLOUDREPORT_VERSION_MANIFEST ?? 'version.json'
const tagPattern = /^\d+\.\d+\.\d+\.\d+$/

function compareVersions(left, right) {
  const leftParts = left.split('.').map(Number)
  const rightParts = right.split('.').map(Number)

  for (let index = 0; index < Math.max(leftParts.length, rightParts.length); index += 1) {
    const difference = (leftParts[index] ?? 0) - (rightParts[index] ?? 0)
    if (difference !== 0) {
      return difference
    }
  }

  return 0
}

async function fetchPublishedTags() {
  const tags = []
  let nextUrl = `https://hub.docker.com/v2/repositories/${repository}/tags?page_size=100`

  while (nextUrl) {
    const response = await fetch(nextUrl, {
      headers: { Accept: 'application/json' },
      signal: AbortSignal.timeout(30_000),
    })

    if (!response.ok) {
      throw new Error(`Docker Hub returned HTTP ${response.status} for ${nextUrl}`)
    }

    const page = await response.json()
    tags.push(...page.results)
    nextUrl = page.next
  }

  return tags
}

const tags = await fetchPublishedTags()
const latest = tags
  .filter((tag) => tagPattern.test(tag.name))
  .sort((left, right) => compareVersions(right.name, left.name))[0]

if (!latest) {
  throw new Error(`No four-part version tag was found for ${repository}`)
}

const manifest = JSON.parse(await readFile(manifestPath, 'utf8'))
manifest.version = latest.name
manifest.publishedAtUtc = latest.last_updated
manifest.image = `docker.io/${repository}:${latest.name}`

await writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`, 'utf8')
console.log(`Public version manifest synchronized with ${manifest.image}`)
